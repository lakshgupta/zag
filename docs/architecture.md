# Zag Architecture

Approved architecture specs for the Zag compiler and standard library. Each
feature below is written to be implementable directly from this document.

## Index

- [Index](#index)
- [System Context](#system-context)
- [Feature: Fail-Closed Syscall Error Handling](#feature-fail-closed-syscall-error-handling)
  - [Status](#status)
  - [Summary](#summary)
  - [Problem](#problem)
  - [Goals](#goals)
  - [Non-Goals](#non-goals)
  - [User Experience](#user-experience)
  - [Architecture](#architecture)
  - [Data And Interfaces](#data-and-interfaces)
  - [Control Flow](#control-flow)
  - [Edge Cases And Failure Modes](#edge-cases-and-failure-modes)
  - [Testing Strategy](#testing-strategy)
  - [Implementation Plan](#implementation-plan)
  - [Companion Compiler Fixes](#companion-compiler-fixes-landed-with-p0)
  - [Known Coverage Gap](#known-coverage-gap)
  - [Verified Language Constraints](#verified-language-constraints)
  - [Risks And Tradeoffs](#risks-and-tradeoffs)
  - [Resolved Decisions](#resolved-decisions)
  - [Follow-Ups](#follow-ups)
  - [Open Questions](#open-questions)

## System Context

Zag is a systems language that emits Zig source and uses `zig` for native
codegen and linking. The pipeline is:

```
src/main.zig → lexer → parser → ast → codegen → Zig source → zig build-exe
```

There are two modes: file mode (`zag run <file.zag>`) and project mode
(`zag run`, reading `zag.toml`, emitting `build/bin/<name>`). The Zig
toolchain is resolved from an embedded ELF-validated payload, then
`$ZAG_ZIG_PATH`.

Two distinct codebases use syscalls, and this document treats them separately
because their error-handling facilities differ:

| Codebase | Language | Error facility |
|---|---|---|
| `src/` (the compiler) | Zig | Zig error unions + raw `std.os.linux.*` |
| `lib/std/` (the Zag stdlib) | Zag | `Result(T, E)`, `?T`, `match`, `if let` |

The compiler already uses Zig error unions widely (109 `catch` sites in
`src/main.zig`), but its raw syscall sites bypass them. The Zag stdlib has
`Result` available and uses it in exactly one place (`std.fs.read_file`).
This feature closes both gaps with one design.

## Feature: Fail-Closed Syscall Error Handling

### Status

`Approved` — implemented. **P0, P1, P2, P4 and P5 are complete and
verified, and the discarded-result audit gates both trees (`lib/std` and
`src`).** `std.posix` exposes the canonical `Result(T, Errno)` tier plus
its `raw_*` escape hatch, `std.fs.File` is rebuilt on that tier (parent
directory retained, every fallible method a `Result`, durability built
into `close_durable`), and the compiler's own IO fails closed (the file
and artifact read/write paths, the stdlib materialisation walker, and the
subprocess capture loops). P5 landed the injectable errno rows and the
manual/spec sweep; P3 was absorbed by P1. See
[Implementation Plan](#implementation-plan).

### Summary

Two coordinated changes:

1. **`lib/std/posix.zag` gets one error convention.** Its 27 syscalls split
   into a canonical `Result(T, Errno)` tier and a small, explicitly named
   `raw_*` escape hatch for IO hot loops. A new `lib/std/errno.zag` module
   carries the error vocabulary. The EINTR-retry logic currently duplicated in
   four modules becomes one shared helper per direction.
2. **`std.fs.File` is rebuilt on that tier.** The handle retains its parent
   directory path, every fallible operation returns `Result`, the failing
   policy is the postfix `!` operator at the CALL SITE (one spelling per
   operation, so no `*_or_panic` twins exist), and directory durability is
   built into the contract rather than bolted onto a free function.
3. **The compiler gets `src/sys.zig`.** All raw syscall call sites route
   through it, so errno is inspected in one place and no write can be reported
   as successful after failing.

The guiding principle is *fail closed*: an operation that cannot complete
returns an error value, and an operation that cannot report an error must be
visible in its name.

### Problem

#### `std.posix` has three competing error conventions

Call sites must hand-roll the check, because the convention depends on the
function:

- **`isize` with negative errno:** `read`, `write`, `pread`, `pwrite`, `lseek`
- **`usize` with a high-bit-set errno:** `openat`, `close`, `fsync`,
  `fdatasync`, `ftruncate`, `mkdirat`, `getdents64`, `mmap`, `munmap`,
  `nanosleep`, `clone`, `wait4`, `futex_wait`, `futex_wake`,
  `futex_wait_shared`
- **Sentinel collapses:** `spawn -> 255` (indistinguishable from a child that
  legitimately exited 255), `getcwd -> ""`, `getenv -> null`, and `openat`
  fabricating `0xFFFFFFFFFFFFFFFF` for a too-long path — a non-errno condition
  wearing an errno (it decodes as `EPERM`).

Every caller re-derives the sign test by hand, and the EINTR retry loop is
duplicated in `lib/std/io.zag`, `lib/std/fs.zag`, `lib/std/posix.zag`, and
`lib/std/random.zag`. Four copies of the same policy is where the recently
fixed read/write bugs came from.

#### `File` cannot express failure

`close` and `sync` return `void`, so a deferred `ENOSPC`/`EIO` reported only at
close is either dropped or converted into a panic with no recovery path.
`try_open` returns an `fd == -1` sentinel instead of a `Result`. The handle does
not retain its path, so `create` cannot fsync the containing directory — the
durability guarantee exists only inside the free function `write_file`.

#### The compiler is error-blind

`src/` contains **98 raw syscall call sites, 2 sign-bit checks, and no EINTR
handling anywhere.** The concrete consequences:

- **`writeFile` reports success on a failed write.** It does
  `if (n == 0) return error.WriteFailed; written += n;`. An errno-encoded
  `usize` is *nonzero*, so `written` overflows past `content.len`, the loop
  exits, and the caller believes the file was written.
- **`readFile` has the same shape** (`total += n`) and can then slice
  `file_buf[0..total]` past the end of the buffer.
- **`mkPath` discards the `mkdirat` result entirely**, so it cannot distinguish
  `EEXIST` (expected) from `EACCES`/`ENOENT` (not).
- **`materializeStdlib` / `materializeWalk` returned `void`** and swallowed
  every transpile and write failure, so a broken stdlib materialisation
  surfaced much later as a confusing zig `@import` error. *(Fixed — see P4.)*
- **`runCommandCaptured` treated a stderr-read errno as EOF**, silently
  discarding the very output the remap pass needs. *(Fixed — see P4.)*
  `captureCommand` had the same loop with a dead `if (n < 0) break`, and there
  the errno-encoded return pushed the cursor past its buffer. *(Fixed.)*
  `readFirstMapEntry` and `parseArgs` were the same defect twice more — one
  slicing past a stack buffer, one producing a bogus argv. *(Fixed — see P4.)*
- **`close` results are discarded 41 times**; `execve`, `dup2`, and `waitpid`
  results are discarded in the child and parent paths. *(Not yet fixed.)*

### Goals

- One error convention in `std.posix`, documented once, with typed errors that
  name the errno.
- No syscall result in `lib/std` or `src/` is inspected with a hand-written
  magic-number test.
- Every fallible operation has a recoverable form; the panicking form is
  explicit in its name.
- EINTR retry exists in exactly one place per direction.
- A failed write, close, fsync, or directory-fsync can never be reported as
  success — in the stdlib or in the compiler.
- Compiler file and artifact writes fail closed and produce a diagnostic that
  names the path and the errno.

### Non-Goals

- **No build-time fsync for regenerable artifacts.** Generated `.zig`,
  `.zag.map`, and gdb-init files are not fsynced. Only user-visible durable
  artifacts (`zag.lock`, `zag init` scaffolding) use the durable write path.
- **No `strerror` table.** `Errno.name()` exists for diagnostics; message
  lookup is out of scope.
- **No structured error chains.** `std.error.Context` exists but wiring it
  through every fallible layer is a separate feature.
- **No `Result` conversion for `src/`.** The compiler is Zig and already has
  error unions; it needs errno discipline, not a new error type.
- **No fix for the three pre-existing codegen limitations** recorded under
  [Verified Language Constraints](#verified-language-constraints). They are
  worked around and documented.

### User Experience

The language surface does not change. What changes is what a program can
observe:

```zag
# before — a real failure is a crash, and there is no way to see it
var f: File = File.create("db.pages");
f.close();                              # a deferred ENOSPC vanishes here

# after — failure is a value, and closing is a decision the compiler requires
var f: File = File.open("db.pages", FileMode.Create)?;
match f.close() {
    Ok(_) => {}
    Err(e) => print("close failed: {e.name()}"),
}

# the failure policy is explicit at the CALL SITE
File.open("maybe", FileMode.Read)?;     # Result(File, Error)
f.close()!;                             # "I am a fixture. Crash on failure."
```

A library thus publishes ONE function per operation; `!` is the panicking
spelling of the very same call the recoverable spelling uses, so an example
keeps its output while no name pair can drift out of step.

Because Zig rejects an ignored non-void return value, every migrated call site
becomes a compile error until it either handles the error or names an
intentional discard. The migration is therefore compiler-enforced rather than
review-enforced.

### Architecture

Three stdlib layers, each with a single job, and a compiler-side mirror.

```
  user code
     │  fmt / io / fs / storage
     ▼
  std.fs.File  ──────────────  ergonomic tier
     │   path-retaining, Result-returning, durable, std.error.Error
     ▼
  std.posix     ──────────────  syscall tier
     │   Result(T, Errno) canonical names  +  raw_* kernel-faithful names
     ▼
  std.errno     ──────────────  error vocabulary
        Errno { kind: ErrnoKind, code: isize }, shared is_err / errno_of
```

```
  src/main.zig  src/project.zig  src/toolchain.zig  src/env_path.zig
     │
     ▼
  src/sys.zig   ── isErr / errnoOf / errnoName / readFull / writeFull /
                   closeChecked / closeOnErrorPath / mkdirPath / writeFile /
                   writeFileDurable / readFile / waitPid / waitPidOrIgnore
     │
     ▼
  std.os.linux (raw)
```

`std.errno` and `src/sys.zig` exist for the same reason: the sign-bit test and
the EINTR loop each live in exactly one place, and `readFile`/`writeFile` have
exactly one implementation instead of the current per-caller duplicates.

**Tier boundary rule.** The `raw_*` tier is for loops that already own their
errno policy — the byte loops in `std.io`, `std.fs`, and `std.posix`'s own
`read_full`/`write_full`. Everything else uses the canonical `Result` names.
The shared `read_full`/`write_full` helpers mean the common case needs no raw
access at all.

### Data And Interfaces

#### New module: `lib/std/errno.zag`

```zag
## The kernel's error vocabulary. `kind` is the branch target; `code`
## is the exact kernel errno, kept so a diagnostic never degrades to
## "UNKNOWN" for an errno the named set does not cover.
pub enum ErrnoKind {
    Eperm, Noent, Eintr, Eio, Enxio, Ebadf, Eagain, Enomem, Eacces,
    Efault, Eexist, Einval, Enfile, Emfile, Enospc, Espipe, Erofs,
    Epipe, Erange, Enametoolong, Enosys, Enotempty, Eloop, Etimedout,
    Econnrefused, Eoverflow, Unknown,
}

pub struct Errno {
    kind: ErrnoKind,
    code: isize,
}

## Named codes, for the raw tier and for call sites that need the number.
pub const ENOENT: isize = 2;
pub const EINTR: isize = 4;
pub const EACCES: isize = 13;
pub const EEXIST: isize = 17;
pub const EINVAL: isize = 22;
pub const ENOSPC: isize = 28;
## ... roughly 30 codes in total.

impl Errno {
    pub fun of(code: isize) -> Errno;      # explicit match, not enum_from_int
    pub fun is(self: Errno, k: ErrnoKind) -> bool;
    pub fun name(self: Errno) -> str;      # "ENOSPC", or "errno 95"
}

## The one place the two raw conventions are decoded.
pub fun is_err(rc: usize) -> bool;         # sign-bit test
pub fun errno_of(rc: usize) -> Errno;      # decode -> Errno
pub fun errno_of_signed(rc: isize) -> Errno;
```

`Errno.of` must be an explicit `match` over integer patterns. `enum_from_int`
is not usable here — see
[Verified Language Constraints](#verified-language-constraints).

#### `lib/std/posix.zag` — the tier split

| Canonical (`Result`) | Raw escape hatch | Notes |
|---|---|---|
| `openat(dirfd, path, flags, mode) -> Result(i32, Errno)` | `raw_openat -> usize` | over-long path becomes `Err(Einval)`, not a fabricated `EPERM` |
| `close(fd) -> Result(void, Errno)` | `raw_close -> usize` | |
| `read(fd, buf, len) -> Result(usize, Errno)` | `raw_read -> isize` | |
| `write(fd, buf, len) -> Result(usize, Errno)` | `raw_write -> isize` | |
| `pread` / `pwrite` | `raw_*` | positioned page IO |
| `lseek(fd, off, whence) -> Result(i64, Errno)` | `raw_lseek -> isize` | |
| `ftruncate` / `fsync` / `fdatasync` -> `Result(void, Errno)` | `raw_*` | |
| `mkdirat -> Result(void, Errno)` | `raw_mkdirat` | `EEXIST` becomes a typed value the caller may coalesce |
| `getdents64 -> Result(usize, Errno)` | `raw_getdents64` | |
| `mmap -> Result([*]u8, Errno)` | `raw_mmap` | |
| `munmap -> Result(void, Errno)` | `raw_munmap` | |
| `nanosleep -> Result(void, Errno)` | `raw_nanosleep` | EINTR surfaces; the caller owns retry policy |
| `read_full(fd, buf) -> Result(usize, Errno)` | — | **single home of the read-side EINTR loop** |
| `write_full(fd, bytes) -> Result(usize, Errno)` | — | **single home of the write-side EINTR loop** |
| `clone -> Result(usize, Errno)` | `raw_clone` | `Ok(0)` in the child, `Ok(tid)` in the parent |
| `wait4 -> Result(i32, Errno)` | `raw_wait4` | |
| `futex_wait` / `futex_wake` -> `Result(void, Errno)` | `raw_*` | `Eagain` is a normal outcome, documented |
| `getcwd -> Result([]const u8, Errno)` | — | replaces the `""` sentinel |
| `clock_gettime -> Result(i64, Errno)` | — | |
| `spawn(cmd) -> Result(i32, Errno)` | — | arena/argv overflow becomes `Einval`/`Enomem`; the `255` ambiguity is removed |

`getenv -> ?str` and `argv -> []const []const u8` keep their current shape. An
unset variable and a missing argument vector are not errno conditions, and
`?str` is already the documented borrowed-view contract.

`std.posix.openat`'s too-long-path guard returns `Err(Einval)` instead of
`0xFFFFFFFFFFFFFFFF`. This is a behaviour change: the fake value currently
decodes as `EPERM`, which is why `openat` failures on long paths looked like
permission errors.

#### `std.fs.File` — changed contract

```zag
pub struct File {
    fd: i32,
    parent: [512]u8,     # parent directory of the path this handle was opened with
    parent_len: usize,
    created: bool,       # opened with O_CREAT — the directory entry may need flushing
}

impl File {
    # ONE constructor, mode explicit: Read / Rw / Append / Create. A
    # one-argument `open(path)` overload cannot be used here because File
    # is a cross-module type and overloading resolves against the
    # declaring module's `impl` table (docs/manual/30 §Across modules).
    pub fun open(path: str, mode: FileMode) -> Result(File, Error)

    pub fun close(self: *File)         -> Result(void, Error)
    pub fun close_durable(self: *File) -> Result(void, Error)  # fsync + close + parent fsync

    pub fun sync(self: *File)          -> Result(void, Error)
    pub fun datasync(self: *File)      -> Result(void, Error)
    pub fun read_at(self: *File, buf: []u8, off: i64)          -> Result(usize, Error)
    pub fun write_at(self: *File, bytes: []const u8, off: i64) -> Result(usize, Error)
    pub fun append(self: *File, bytes: []const u8)             -> Result(usize, Error)
    pub fun truncate(self: *File, n: usize)                    -> Result(void, Error)
    pub fun size(self: *File)          -> Result(usize, Error)
    pub fun read_block(self: *File, id: u64, buf: []u8)        -> Result(bool, Error)
    pub fun write_block(self: *File, id: u64, bytes: []const u8) -> Result(void, Error)
    pub fun fsync_parent(self: *File)  -> Result(void, Error)
    pub fun is_open(self: *File)       -> bool
}
```

`try_open` is removed: `open` already returns a `Result`, so the `fd == -1`
sentinel it published was a second, weaker failure channel; `is_open()` is the
probe that replaced it.

Free functions publish one spelling each. The panicking `read_file` / `i32`
`write_file` pair is gone: `read_file(p)!` and `write_file(p, c)!` are the
fail-fast forms of the same Result calls:

| Function | Contract |
|---|---|
| `read_file(path) -> Result(String, Error)` | never panics; `read_file(p)!` panics at the call site |
| `write_file(path, content) -> Result(usize, Error)` | `Ok(n)` only when bytes *and* the directory entry are durable |

`File` grows from 4 bytes to roughly 528 bytes because the parent path is
embedded. This was checked across `lib/std` and `examples/`: `File` is used as
a local handle, never in a large array, so the stack cost is acceptable. If it
ever becomes hot, the parent path moves behind a pointer.

**Move-only by convention.** `File` is returned by value and `close(self: *File)`
invalidates the handle. Two copies of one `File` would double-close. This hazard
already exists today; the contract change documents it explicitly rather than
introducing it.

#### Error mapping at the `fs` tier

`Errno` collapses into the canonical `std.error.Error` variants, matching what
`read_file` already publishes:

| Errno | `std.error.Error` |
|---|---|
| `ENOENT` | `NotFound` |
| `EPERM`, `EACCES` | `Permission` |
| everything else | `Io` |

Callers that need to distinguish `ENOSPC` from `EIO` use the posix tier or
`write_file`, which preserve the code.

#### Compiler: `src/sys.zig`

```zig
pub fn isErr(rc: usize) bool;
pub fn errnoOf(rc: usize) isize;
pub fn errnoName(errno: isize) []const u8;

pub fn readFull(fd: i32, buf: []u8) !usize;        // retries EINTR
pub fn writeFull(fd: i32, bytes: []const u8) !void; // retries EINTR
pub fn closeChecked(fd: i32) !void;
pub fn closeOnErrorPath(fd: i32) void;              // primary error already in hand
pub fn waitPid(pid: i32) !u32;                      // retries EINTR, decodes errno
pub fn waitPidOrIgnore(pid: i32) void;              // reap-only (avoid a zombie)
pub fn mkdirPath(path: []const u8) !void;           // EEXIST is success

pub const Durability = enum { report_only, durable };
pub fn writeFile(path: []const u8, content: []const u8, durability: Durability) !void;
pub fn readFile(path: []const u8) ![]const u8;
```

`writeFile` with `.durable` performs the file fsync, the checked close, and the
parent-directory fsync. Generated artifacts use `.report_only`: they must
*report* failure, but need not be durable.

### Control Flow

A durable create-and-write, end to end:

```
write_file(path, content)
  ├─ File.open(path, FileMode.Create) → openat(O_RDWR|O_CREAT|O_TRUNC)
  │     ✔ Ok(fd)                    → parent = dir_of(path), created = true
  │     ✘ Err(errno)                → Err(map(errno))          [ENOENT → NotFound]
  ├─ write_full(fd, content)        → retries EINTR, loops short writes
  │     ✘ partial or failed         → close, Err(Io)
  ├─ fsync(fd)                      → surfaces buffered-writeback ENOSPC here
  │     ✘ Errno                     → close, Err(Io)
  ├─ close(fd)                      → surfaces deferred writeback error
  │     ✘ Errno                     → Err(Io)
  └─ fsync_parent()                 → open parent dir O_RDONLY, fsync, close
        ✘ EINVAL / ENOTSUP          → tolerated, Ok   (fs lacks dir fsync)
        ✘ anything else             → Err(Io)
```

Compiler side, the same shape:

```
sys.writeFile(path, bytes, durability)
  ├─ openat  ✘ → error.WriteFailed with errnoName() in the diagnostic
  ├─ writeFull ✘ → error.WriteFailed
  ├─ [durable only] fsync ✘ → error.WriteFailed
  ├─ closeChecked ✘ → error.WriteFailed
  └─ [durable only] fsync parent ✘ → error.WriteFailed, except EINVAL/ENOTSUP
```

Callers report `zag: cannot write <path>: errno <name>`. Today the same failure
is either silent or a bare `error.WriteFailed` with no path.

`sys.mkdirPath` distinguishes `EEXIST` (success) from every other errno
(propagated). Today `mkPath` cannot, and `materializeStdlib` cannot report
anything at all — it becomes a `!void` function whose error is propagated to
the caller and reported.

### Edge Cases And Failure Modes

| Condition | How to inject deterministically | Required behaviour |
|---|---|---|
| `ENOENT` | missing path | `Err(NotFound)`, no panic |
| `EACCES` | `chmod 000` on a directory | `Err(Permission)` |
| `EISDIR` | `read(fd)` on a directory fd | `Err(Io)`; never a 0-byte "success" |
| `ENOSPC` | `/dev/full` | `Err` from the write *and* from `fsync`/`close` |
| `EEXIST` | `mkdir` twice | success (coalesced), not an error |
| `EBADF` | write to a closed handle | `Err(Io)`, `is_open() == false` |
| `ENAMETOOLONG` | path ≥ 4096 bytes | `Err(Einval)` from `openat`, not a fabricated `EPERM` |
| `EINTR` | signal before any bytes move | retried inside `read_full`/`write_full`; never surfaces |
| `EAGAIN` | `futex_wait` on a changed word | normal outcome, documented as such |
| dir-fsync unsupported | filesystem without it | `EINVAL`/`ENOTSUP` tolerated — a weaker guarantee, not a failure |
| oversized `spawn` argv | > 64 args, or > 16 KiB arena | `Err(Einval)` / `Err(Enomem)`, no longer a bare `255` |

EINTR cannot be injected at the Zag level because `std.posix` has no
`sigaction`/`signal` binding. Its coverage is structural: the retry loop is
asserted in the generated Zig and exercised by reading the helper's source
shape in a codegen pin.

### Testing Strategy

1. **Unit tests (`zig build test`).** `src/sys.zig` gets direct Zig tests:
   `isErr`/`errnoOf` over synthetic high-bit values, `writeFull` stopping on a
   real errno instead of the errno-encoded value, `mkdirPath` treating `EEXIST`
   as success. *Landed:* plus `readSome` over a real pipe (one transfer, then
   `Ok(0)` at EOF, `EBADF` on a bad fd), `openReadOnly` on a file and a
   directory, and `dirEntries` decoding `ENOTDIR` instead of reporting an empty
   directory. Codegen pins in `src/tests/` are updated if the `Result` prelude
   usage changes.
2. **Zag-level tests (`@[test]` blocks).** *Landed:* every injectable row of
   the table above is covered — `ENOENT` (missing path), `EACCES`, `EISDIR`,
   `ENOSPC`, `EEXIST` (double `mkdir`), `EINVAL` (4096-byte path, oversized
   argv), `EBADF` (double close, op on a closed handle), and `EAGAIN`
   (`futex_wait` on a changed word). Each is deterministic, and none needs a
   signal handler or a `chmod` binding: the file mode is passed at `openat`
   time, so a `0o444` file *is* the `EACCES` injection, and `/dev/full`
   supplies `ENOSPC`. A row whose host feature is absent skips itself.
3. **Contract pins.** `tests/scaffold.zig`'s import-count assertion is updated
   as the barrel changes. Per-feature pins are added for `Errno`, `read_full`,
   and the `File` surface so a rename cannot silently drop a module.
4. **Compiler end-to-end (`zig build e2e`, `zig build smoke`).** A read-only
   output directory must make `zag build` fail with a path-naming diagnostic
   rather than a confusing zig error. `zag init` into an unwritable directory
   must fail closed. A lockfile write failure must be reported.
   *Verified by hand* for `build/gen/std` as a regular file (`ENOTDIR`) and as
   a directory-where-a-file-goes (`EISDIR`), an unreadable `lib/std/*.zag`
   (`EACCES`), and a missing stdlib root — each exits 1 with the failing path
   in the message. These are not yet wired into an automated step (see
   [Known Coverage Gap](#known-coverage-gap)).
5. **Regression guard — the important one. LANDED** as `zig build audit`, a
   custom `std.Build.Step` that fails the build. The compiler's unused-value
   rule cannot catch this, because `_ =` is exactly how a hole gets re-opened
   silently — so the rule is not "never discard" but "name the decision":
   every discard of an audited callee must carry the phrase
   `deliberate discard` in a comment on the same line.

   Audited callees are the close/sync + transfer family (`close`, `sync`,
   `fsync`, `fdatasync`, `datasync`, `write`/`write_full`/`write_at`/
   `write_block`, `pwrite`/`pwrite_full`, `append`, `read`/`read_full`/
   `read_some`/`read_at`/`read_block`, `pread`/`pread_full`). Matching is on
   the callee's last `.`-segment, so `f.close()`, `close(fd)`, and
   `std.posix.close(fd)` are one call. Comment lines and Zig multiline-string
   bodies are skipped, so the codegen's *emitted* `_ = std.os.linux.close(fd);`
   templates are not judged as compiler code.

   *Triage of the eight sites the audit flagged in `lib/std`:* all eight are
   genuinely deliberate and now say so in-line — `posix.zag`'s three
   `/proc/self/{environ,cmdline}` read paths (getenv, argv, spawn), `random.zag`'s
   three `/dev/urandom` read paths (error, short read, success), and
   `fs.zag`'s two error paths in `read_file` / `write_file` (the primary
   errno is what the caller needs; a close error cannot improve it). **No hole
   was found**; the audit's value is that the argument is now
   machine-checkable instead of prose, and a ninth site cannot appear
   unannounced.

   *Scope:* the audit gates **both trees — `lib/std/**/*.zag` (Zag) and
   `src/**/*.zig` (the compiler)** — and both are compliant, which is what
   lets the step gate them. The `src/` pass is what converted P4's "remaining"
   list into work: 49 files, 40 audited discards, of which **12 were real
   bugs, not discards to name** (see [P4](#implementation-plan)) and the other
   28 are read-only/probe closes now marked in-line.

   A walk that finds no file is itself a violation rather than a silent pass.
   That guard is not hypothetical: the first version of the scanner hardcoded
   `.zag` for both roots, so the `src` pass scanned zero files and printed
   `0 violation(s)` — indistinguishable from a clean tree. The step now prints
   `{files} file(s), {sites} audited discard(s), {violations} violation(s)` per
   root so a no-op scan is visible.

   Also out of scope, named in the step's own doc comment: `futex_wait`/
   `futex_wake` (a spurious wakeup is a legitimate non-error return, so a
   per-site marker would be noise), `nanosleep_retry`, `fetch_add`/`release`,
   `execve` (returns only on failure, immediately followed by `exit(127)`), and
   `mkdirat`/`mkdir`/`unlink` (`EEXIST`/`ENOENT` are the expected results).

   `zig build test` depends on the audit step, so the gate rides along with the
   project's fast primary check; `zig build audit` runs it alone. Proven to
   fail: stripping one marker yields `error: 1 discarded result(s) in lib/std
   lack a \`deliberate discard\` marker` and exit 1 with the path and line.
6. **Unchanged gates.** `zig build test` (514/514 **plus the audit step, 5/5
   build steps**), `zig build scaffold_tests`
   (**17/17**), `zig build example_tests` (**134 assertions** across 73
   file-mode fixtures + 1 project — run by CI's test job alongside
   `zig build test`), and the full `examples/run_all.sh` baseline (**90/91**,
   with only the documented negative fixture `traits/ambiguous_diamond.zag`
   failing). The example count moved 89→90 when
   `examples/error-handling/posix_tier.zag` landed with P1; its 10 `@[test]`
   blocks run under `zag test`, as do `io_robustness.zag`'s 11 (P2 added the
   `File` contract rows — `Result`-shaped open, a retained parent, the
   durable close, ops on a closed handle, the double close, the wrong-sized
   block buffer, and `write_file`'s Ok/Err — and P5 added the `EACCES`,
   `EISDIR` and `ENOSPC` injections to both fixtures).
7. **API-surface pins.** `tests/scaffold.zig` asserts the barrel's import
   count and dotted paths — and, since P2, the selectors on the
   recoverable-IO line — so a re-export cannot be dropped silently. That is
   the only automated check that a `lib/std` module is still wired to the
   barrel; it is parse-only, so it catches removal but not a wrong signature.
   P2 added the `stub_fs` stub so fs.zag's `File` surface is pinned by name
   (see the P2 note above).

### Implementation Plan

Six phases. P0–P2 are stdlib-internal and each leaves the tree green and
shippable; P3–P4 touch `src/` broadly and should land as their own commits so
`git bisect` stays useful.

**P0 — vocabulary and shared helpers. — COMPLETE.**

Added `lib/std/errno.zag`: `ErrnoKind`, `Errno { kind, code }` with
`of`/`is`/`name`, 41 named codes, and `is_err`/`errno_of`/`errno_of_signed`.
Added the shared transfer helpers to `std.posix`: `read_some`, `read_full`,
`write_full`, `pread_some`, `pwrite_full` (all returning
`Result(usize, Errno)`) plus the `EINTR_RC` constant. Deleted all four
duplicated EINTR loops — `io.zag`'s `read_retry`/`write_retry`, `fs.zag`'s
inline loops in `read_file`/`write_file`/`try_read` and its
`pread_retry`/`pwrite_retry`/`write_retry` wrappers, `posix.zag`'s private
`read_full`, and `random.zag`'s inline loop — and routed every call site
through the shared helpers.

Deliberate split recorded while implementing: `read_line`, `read_all`, and
`FileReader.fill` use `read_some` (a SINGLE transfer), **not** `read_full`.
A line reader hands back whatever one `read(2)` produced; draining the
buffer would block until EOF instead of returning the line. Only
whole-file and whole-slice paths use the `*_full` variants.

No public signature changed at P0: `try_read` kept `Result(usize, Error)`
and `File`'s methods kept their shapes; P0 was purely additive at the API
level. (P2 and the `!` collapse later removed the panicking `read_file` /
`i32 write_file` pair and the `*_or_panic` twins — see the P2 section.)

Three compiler problems had to be fixed to land this; see
[Companion Compiler Fixes](#companion-compiler-fixes-landed-with-p0).

**P1 — posix tier split. — COMPLETE.**

`lib/std/posix.zag` now exposes every fallible entry twice: the canonical
name returns `Result(T, Errno)`, `raw_<name>` returns the kernel's value
verbatim (`usize` with bit 63 set, or a negative `isize`). Twenty entries
gained a `raw_` twin; four deliberately did not:

| No `raw_` twin | Why |
|---|---|
| `clock_gettime` | needs the `timespec` out-parameter as well as the rc; no caller wants the raw shape |
| `getcwd` | same — the length and the buffer must travel together |
| `spawn` | a composition (arena + environ + fork + execve + waitpid), not one syscall |
| `gettid` | cannot fail |

Decoding is centralised in three private helpers — `check_void(usize)`,
`check_count(isize)`, and `err_rc(isize)` — so no canonical entry repeats
the test. The `*_some` / `*_full` transfer helpers call `raw_read` /
`raw_write` directly: they are the "loops that own their errno policy"
the escape hatch exists for, and routing each iteration through a second
`Result` round trip would be pure overhead.

Behaviour fixes landed with the split:

- **`openat`'s over-long path is `Err(EINVAL)`**, not the fabricated
  `0xFFFFFFFFFFFFFFFF` (which decodes as `EPERM`. Every over-long-path
  failure in lib/std used to present itself as a permissions bug).
- **`getcwd`'s failure test was wrong.** `std.os.linux.getcwd` is the raw
  `syscall2` wrapper, so failure is errno-encoded — the old `if (n == 0)`
  test let an errno through and then indexed `cwd_buf[n - 1]` with it.
- **`spawn`'s `255` collapse is gone.** Setup failures (empty argv,
  arena/pointer-array overflow, fork/waitpid errno, unreadable environ)
  are `Err(EINVAL)`/`Err(ENOMEM)`; `Ok(255)` is now unambiguously a
  child's exit code. Two shell conventions survive and are documented in
  the function: a failed `execve` in the child exits 127, and a child
  killed by a signal reports `Ok(255)`.
- **A zero-length `/proc/self/environ` spawns a child with an empty envp**
  instead of failing — an empty environment is legal.

`ErrnoKind` was completed from 29 to 41 variants so it covers every code
`Errno.of` maps: `Enotdir`/`Eisdir`/`Exdev`/`Ebusy`/`Echild`/`Esrch`/
`E2big`/`Enoexec`/`Enodev`/`Enotty`/`Efbig`/`Emlink` were unnameable, so
`e.is(...)` was unavailable for exactly the filesystem failures a caller
most often branches on.

Consumers updated: `fs.zag`, `mem.zag`, `random.zag`, `time.zag`,
`async/loop.zag`, `concurrent/{mutex,once,rwlock,semaphore}.zag`,
`concurrent/thread.zag` (clone), `process.zag`, and the barrel
(`std.errno` re-export). The four futex consumers needed no code change:
`_ = futex_wait(...)` was already the spelling, and it still is — now it
is an explicit discard of a non-void result rather than of a raw `usize`.
`lib/std` contains **zero sign-bit tests** outside `errno.zag`.

New runtime fixture: `examples/error-handling/posix_tier.zag` (10 `@[test]`
blocks + a demo `main`; P5 grew it from 7 with the `EACCES`, `EISDIR` and
`ENOSPC` injections).

**P2 — `File` rebuild. — COMPLETE.**

The handle is now `{ fd, parent: [PARENT_CAP]u8, parent_len, created }`
(528 bytes; 4 before). `open_flags` captures `dir_of(path)` into `parent`
and records whether `O_CREAT` was passed. Every fallible method returns
`Result(_, Error)`: `open(path, mode)`, `read_at`, `write_at`,
`read_block`, `write_block`, `append`, `size`, `block_count`,
`truncate`, `sync`, `datasync`, `fsync_parent`, `close`, `close_durable`.
`is_open` is the one member that cannot fail.

**Superseded while landing (the `!` collapse).** Three renames happened
after P2's plan was written, and the rest of this document describes the
LANDED surface:

1. P2's plan gave every fallible member a `*_or_panic` twin. The `!`
   operator (docs/manual/19) replaced them: the failure policy is chosen
   at the call site, so `f.sync()!` superseded `f.sync_or_panic()` and
   there is exactly one spelling of each operation.
2. The plan kept the four constructor names. They collapsed into
   `File.open(path, mode)` with a mandatory `FileMode` — NOT a
   one-argument overload, because `File` is a cross-module type and
   overloading resolves against the declaring module's `impl` table,
   which an importing module cannot see (docs/manual/30 §Across
   modules).
3. The plan kept the `_or` policy suffix on the free-function twins
   (`read_file_or` / `write_file_or`). With the twins gone the suffix
   disambiguated nothing, so `read_file` / `write_file` are now the
   Result-returning free functions and `read_file(p)!` /
   `write_file(p, c)!` are their fail-fast forms. Any `_or` spelling in
   this document survives only inside historical narrative.

`try_open` is also gone, along with the panicking `read_file` and the
`i32`-collapsing `write_file`. The barrel, examples, the manual, and the
scaffold pins were migrated so `examples/run_all.sh` keeps its baseline.

Decisions taken while implementing:

- **`close()` on an already-closed handle is `Ok(undefined)`.** The
  postcondition (no open fd) already holds, and this preserves the
  pre-P2 no-op semantics for fixtures that close defensively. The
  double-close *detector* stays at the posix tier, where the second
  `close(2)` really is `EBADF`; `size()`/`read_at`/… on a closed handle
  are `Err(Io)`, as the edge-case table requires.
- **A parent that does not fit in `PARENT_CAP` (512) fails closed.**
  The path still opens — nothing about the *file* is limited — but
  `parent_len` stays 0, `fsync_parent` returns `Err(Io)`, and therefore
  `close_durable` on a created handle is an `Err` rather than a silent
  skip of the directory flush. A plain `close()` still succeeds: the
  caller gets the bytes, just not a durability claim the handle cannot
  prove. Verified against a 526-byte parent (532-byte path).
- **`created` is recorded even when the parent is not retained**, which
  is what makes the case above fail closed instead of looking like an
  ordinary non-creating open.
- **A wrong-sized block buffer is `Err(Error.InvalidInput)`**, not a
  panic: it is a contract violation a caller can recover from, and a
  fixture that wants the old behavior writes `f.read_block(0, buf)!`.
- **`read_file` is the ONE reader; there is no panicking sibling.**
  The pre-P2 pair had two separate openat + read loops that could drift
  (and had); there is now one loop, reached fail-fast as
  `read_file(p)!`. Same for `write_file` over
  `File.close_durable`, which is why the directory-fsync tolerance
  lives in one place instead of in every writer.

Two findings worth recording:

- **`close` inside `impl File` is an ambiguous reference.** The
  container-scoped method name shadows the imported facade entry in the
  emitted zig, so `fsync_parent`'s directory close must be spelled
  `posix_close(...)`. That is exactly what the
  `close as posix_close` selector on the import line was for; the
  compiler caught it (`error: ambiguous reference`), which is why the
  crash-on-ambiguity beats a silently shadowed one.
- **A new scaffold pin exists.** fs.zag is now read into
  `tests/scaffold.zig` as `stub_fs` (build.zig) and pinned by
  `scaffold: std.fs parses with the P2 File surface`: one struct with 4
  fields, the 15 canonical method names, the retired twins +
  constructor names asserted ABSENT, `FileMode` present, the 5 free
  functions (`read_file`, `write_file`, `try_read`, `mkdir`,
  `dir_of`), and the `PAGE_SIZE`/`PARENT_CAP` constants. Project mode
  never materializes fs.zag, so a rename would otherwise surface only
  as a zig error inside a user's build. The barrel test pins the
  `read_file, write_file, try_read, mkdir` selector line and the
  28-import count.

**P3 — process and thread tier. — ABSORBED BY P1.**

P1's Data-And-Interfaces table already listed `spawn` / `clone` / `wait4` /
`futex_*`, so the split took them: they are `Result`-returning now, the
`255` collapse is gone, `Eagain` from `futex_wait` is a documented normal
outcome, `std.concurrent.*` and `std.process` are updated. What remains of
P3's intent is only the part P1 did not touch: a richer `std.process`
surface (pipes, close-on-exec status reporting for the `127` ambiguity
below) — feature work rather than error handling.

**P4 — compiler sweep. — PARTIAL (all transfers routed; handle results
remain)**

`src/sys.zig` exists with `isErr` / `errnoOfUsize` / `errnoOfSigned` /
`errnoName` / `lastErrno` / `lastErrnoName`, `readFull` / `writeFull` /
`closeChecked`, `mkdirPath`, `pathZ`, and `Durability`-aware
`writeFile` / `readFile`. Unit-tested in `src/tests/sys.zig` (registered in
`src/tests.zig`).

**Landed:** the file and artifact paths that carried the defect.
`main.zig`'s `writeFile` and `readFile` are now thin delegations (the raw
loops are gone; `writeFile` can no longer return success after a failed
write, and `readFile` can no longer hand back a slice past its buffer),
as is `writeSyntheticZagMap`. `mkPath` delegates to `sys.mkdirPath`, which
bounds-checks the sentinel copy and distinguishes EEXIST from a real
error. `project.zig`'s second `writeFile` copy is delegated too, and
`createProject`'s two discarded `mkdirat` results now propagate — so
`zag init` fails closed with a diagnostic naming the directory and the
errno instead of printing "created project at ..." and exiting 0. `main()`
reports that failure and exits 1.

**Landed (second slice — materialise + capture):** `materializeStdlib` is now `!void` and
`materializeWalk` is `sys.Error!void` — every swallowed failure
(`getdents64`, the per-file `readFile`, the mirror `mkdirat`, the
transpile `writeFile` and its map side-file) propagates. A new
`materializeFail` records the deepest failing path and
`reportMaterializeFailure` prints `error: cannot materialize stdlib:
<path>: <Error> (<ERRNO>)` and exits 1; a missing stdlib root prints every
location that was tried. `runCommandCaptured` and
`captureCommand` drain their pipes through `sys.readSome`, which retries
EINTR and decodes the errno — the old `n <= 0` / dead `n < 0` tests let a
failed read look like EOF. For `captureCommand` that was a memory-safety
bug, not just a diagnostics one: the errno-encoded `usize` ran
`total += n` past the static buffer and the caller sliced
`captureCommandStatic[0..total]` out of bounds. `sys.zig` gained
`readSome`, `openReadOnly`, and `dirEntries` (and `readFile` now shares
`openReadOnly`); `readFull` is a loop over `readSome`.

A *parse* failure inside a lib/std module is not something the walker can
propagate: `Parser.parse` returns an `ast.Program` unconditionally, and its
failure path (`Parser.expect`) prints `error:line:col:` and calls
`std.process.exit(1)` itself. It is loud and fatal already.

**Landed (third slice — the rest of `main.zig`'s read paths).** While
tracing the capture loops, four more raw reads turned out to be the same
shape. Two were live bugs:

- `readFirstMapEntry` did `read(...)`, then `if (n <= 0) return ""`, then
  `buf[0..@intCast(n)]` — an errno-encoded `usize` is > 0, so a failed read
  of a `.zag.map` sliced ~2^64 bytes past a 4 KiB stack buffer.
- `parseArgs` scanned `cmdline_buf[0..n]` the same way, so a failed
  `/proc/self/cmdline` read "succeeded" with a bogus argv.

`readELFForRemap` tested `bytes_read < 0` on a `usize` (dead) and was only
saved from misreading the errno by its following `!= file_size`;
`readSourceForExpansion` had the last hand-written sign-bit decode in
`src/`, missing the EINTR retry. All four now call `sys.readSome` /
`sys.readFull`, so **`src/main.zig` contains no raw `read` call at all** —
the two `write` calls that remained (the ELF remap patch write-back and the
remapped-stderr emit) were checked in the [P4](#implementation-plan)
completion below — both now go through `sys.writeFile` / `sys.writeFull`.

**P4 — the `src/` discards. — COMPLETE.** Widening the audit to `src`
(Testing Strategy step 5) forced every discard in the tree to be judged. The
result: **17 sites were real bugs and are gone** (removed, not named), and
the remaining **40 audited discards across 49 files are read-only or probe
descriptors, now carrying in-line markers**. The audit's own output for the
tree is `49 file(s), 40 audited discard(s), 0 violation(s)`.

The seventeen:

| Site | Was | Now |
|---|---|---|
| `waitpid` ×5 — `runCommandWithArgs`, `runCommand`, `runCommandCaptured`, `captureCommand` ×2 | result discarded, `status` read straight after — and `status` init to 0 passes `W.IFEXITED`, so **a failed wait reported "exited 0"** | `sys.waitPid(pid)`: retries EINTR, decodes the errno, and the callers report `error.WaitFailed` / code 255 |
| `dup2` + child closes ×6 (both capture paths) | discarded; a failed redirect sends captured output to the terminal, a leaked write end makes the parent's drain-to-EOF never return | `childSetupOrExit(rc, label)`: fail closed with a diagnostic and exit 125 (distinct from 127 = exec failed) **before** `execve` |
| ELF DWARF patch write-back (`lseek` ×2, `write`, `ftruncate`) | all discarded, and the `end_pos < 0` size check was dead code on a `usize` — an errno-encoded size would have trapped in `@intCast` | read side is `openat(O_RDONLY)` with `sys.isErr` on both seeks; the write side is `sys.writeFile(..., .report_only)`, which owns `writeFull` + a **checked close** so a deferred write-back error cannot read as success |
| remapped-stderr emit (`write(2)`) | discarded, so a partial write could cut a diagnostic mid-caret-line | `sys.writeFull(2, ...)` |
| `materializeZigToCache` (found by the same pass) | hand-rolled write loop tested `n == 0` on a `usize` (dead) then added the errno-encoded value to the counter, and the close was discarded | `sys.writeFull` + `sys.closeChecked`: a truncated payload is no longer reported as a materialized zig |

The 40 marked sites are read-only or probe descriptors (`defer _ = close(fd)`
on a directory walk, a `/proc` read, an existence probe); each carries an
in-line `// deliberate discard:` marker stating why close(2) has nothing to
report. Two named escapes exist so a reader can tell those apart from
oversight: `sys.closeOnErrorPath(fd)` (the failure is already in hand) and
`sys.waitPidOrIgnore(pid)` (reap-only, e.g. before returning a read error).
Two of `sys.writeFile`'s error-path closes used to be bare discards and now
call the first of those, so they need no marker at all.

`sys` grew `waitPid`, `waitPidOrIgnore`, `closeOnErrorPath`, `WaitFailed`, and
`ECHILD`; `src/tests/sys.zig` pins the new contract (a forked child exiting 7
must come back as `EXITSTATUS == 7`, and a second wait must be `WaitFailed` /
`ECHILD` rather than a clean-looking 0).

The lockfile and `zag init` writes still use `.report_only` —
switching them to `.durable` is a deliberate follow-up (it adds fsyncs, so it
is a behaviour change rather than a bug fix). `sys.mkdirPath` coalesces every `EEXIST` into success
without an `fstatat` probe (zig 0.16 dropped the binding — AGENTS.md
§4), so a *file* sitting where a directory was wanted is reported by the
subsequent `openat`/`writeFile` (`ENOTDIR`/`EISDIR`) rather than by the
mkdir.

**P5 — examples and docs. — COMPLETE.**

`examples/error-handling/posix_tier.zag` grew from 7 to 10 `@[test]` blocks
and `io_robustness.zag` from 8 to 11, covering the three errno rows that had
no runtime injection. Each is injectable with **no signal handler and no
`chmod` binding** — every one is arranged at open time, so the fixture
creates its own failure:

| Row | Injection | Asserted |
|---|---|---|
| `EACCES` | create `0o444`, then `openat(O_WRONLY)` | `Err(ErrnoKind.Eacces)`; at the fs tier `Error.Permission` from `write_file` and from `File.open(_, FileMode.Rw)`, while `File.open(_, FileMode.Read)` still succeeds — the read bit is what separates "denied" from "unreadable" |
| `EISDIR` | `openat(dir, O_RDONLY)` then `read`, and `openat(dir, O_WRONLY)` | `Err(ErrnoKind.Eisdir)` — **not** `EACCES`; at the fs tier `read_at` is `Error.Io`, never `Ok(0)` |
| `ENOSPC` | `/dev/full` | `Err(ErrnoKind.Enospc)` from `write` and `write_full`; `write_file` reports an `Err`, never a durable success |

Every row skips itself on a host that cannot inject it (root bypasses the
mode bits; a non-Linux host has no `/dev/full`), so the fixtures stay
runnable everywhere.

Docs swept:

- `docs/manual/19-error-handling.md` — new **Errors from the Standard
  Library** section: the errno→`Error` table, `std.errno`'s
  `Errno`/`ErrnoKind` with `is`/`name`/`code`, the two `std.posix` tiers
  and why four entries have no `raw_` twin, and the `File`
  `Result` contract with `close_durable` (call sites spell the policy
  `!` — the twins were retired).
- `docs/manual/32-building.md` — new **Per-example `@[test]` blocks**
  subsection: the file-mode vs project-mode `zag test` invocations and the
  skip-on-missing-fixture / never-panic conventions.
- `docs/spec.md` — the IO errno mapping added to §3.3's Error-type note,
  and §11.3 gains `std.errno` + `std.posix` entries and splits `std.fs`
  out of the catch-all line.
- `README.md` — swept for `File`/`read_file`/`write_file`/`Result`
  snippets; it is install-and-build only and contains none, so no edit was
  needed. Recorded rather than inventing content to justify the sweep.

**The gate.** P5 closed its own coverage hole: `zig build example_tests` runs
`zag test` over the example catalog, one `Run` step per fixture, with the exit
code propagating, and CI's test job invokes it.

Discovery is config-time (`walkExampleDir` in build.zig), not a
hand-maintained list, so a new fixture is gated the moment it lands. Two
signals, matching Zag's two test conventions: a line opening with `@[test]`
(file mode), and a `fun test_*` declaration (the project-mode convention —
`zag test` from a project root treats every top-level `fun test_*` as a case
with no annotation). A `##` comment that merely *mentions* `@[test]` does not
count, which is why `hasTestBlocks` requires the attribute to open the line.

Each fixture then runs FILE MODE or PROJECT MODE depending on whether an
ancestor directory holds a `zag.toml`. Current coverage: **73 file-mode
fixtures + 1 project, 134 assertions** (~50 s wall clock). The project-mode
step collapses to one step per project — `zag test` from a project root
compiles the whole module graph — and it is not optional:
`examples/project_layout/tests/parse.zag` imports the project's `src/lib.zag`,
so file mode cannot even compile it.

Three build.zig details, each found the hard way:

- `ZAG_ZIG_PATH` is pinned to the `zig` the build finds on `$PATH`
  (`detectZigOnPath`), because `zag`'s resolution chain
  (zag.toml -> `$ZAG_ZIG_PATH` -> three fixed paths -> embedded payload) has
  **no `$PATH` tier**, so a CI `setup-zig` install is otherwise invisible.
- The step spawns the **installed** `zig-out/bin/zag-<suffix>` (absolute, via
  `getInstallPath` + `pathResolve`) rather than the cache artifact
  `addRunArtifact` would hand over. Project mode is why: `resolveStdlibRoot`
  finds the stdlib mirror at `<exe_dir>/../../lib/std`, which only lands on
  the repository's `lib/std` from `zig-out/bin/`. `addRunArtifact` worked for
  file mode (cwd = build root, `./lib/std` hits first) and failed every
  project-mode fixture with `error: cannot locate lib/std`.
- The dedupe relies on iteration being sorted by path: every file of a
  project shares that project's prefix, so a project's fixtures are
  contiguous and comparing against the previous root is enough — no set.

A side effect worth recording: project mode writes `build/{bin,gen}` into the
project directory, and `examples/project_layout/.gitignore` covered `deps/`,
`.zig-cache/`, and `zig-out/` but **not `build/`**. Nothing in the automated
flow had ever run project mode, so the gap never showed; the gate exposed it
and `build/` was added. Generated output is therefore still invisible to
`git status` after a gate run.

### Companion Compiler Fixes (landed with P0)

Three compiler problems blocked the plan and were fixed alongside it. All
three made a legal-looking program fail with a confusing error or, in one
case, kill the compiler outright.

**1. `match` with more than 16 arms aborted the compiler.**
`parseMatchExpr` in `src/parser/stmt.zig` collected arms into a `[16]` stack
buffer with no bounds check, so arm 17 indexed past the end and the compiler
died with `index out of bounds: index 16, len 16`. A match with one arm per
enum variant is an ordinary thing to write — `ErrnoKind` alone has 29
variants, so every user `match` on it would have crashed the compiler. The
cap is now `[256]`, matching the `stmts_buf` size the parser uses for other
list-shaped constructs, and a guard reports
`too many match arms (limit 256)` as a parse error instead of crashing.

**2. A statement-position `match` whose arms all end in real statements
didn't compile.** `genMatchExpr` always wrapped the match in a labeled block
`(__blk_N: { … })` and emitted `break :__blk_N EXPR` only for arms that
carry the match's value. When every arm ends in a real statement instead — an
assignment, a `return`, a `break` — nothing breaks the label and zig rejects
it with `unused block label`. That made the idiomatic

```zag
match r {
    Ok(n) => { total = total + n; },
    Err(e) => { return Err(e); },
}
```

fail to compile. `genMatchExpr` now decides up front whether any arm yields a
value (via a shared `armYieldsValue` predicate) and emits an **unlabeled**
block when none does. This is what let the P0 helpers be written in the
natural shape rather than contorting around the bug.

**3. `std.errno` had to be registered as a known std module.**
`KNOWN_STD_MODULES` in `src/parser/core.zig` is the only thing that makes
`import std.<name>` resolvable from user code, and a miss is skipped
**silently** — the import line simply disappears from the emitted zig, and
the error appears much later as a zig `use of undeclared identifier`. This is
the same "failure reported as success" class the plan is about, applied to
the compiler's own module registry. `std.errno` is now registered, and the
table carries a comment warning the next contributor that adding a module
requires an entry here.

Each fix has a regression test in `src/tests/codegen_stmt.zig`: the arm-count
case transpiles a 20-arm match and asserts all 20 scrutinee tests plus 21
value breaks are emitted; the label case asserts an unlabeled `({ const
__m_0 …` block with no `__blk_0` label.

**4. `zag init` reported success while creating nothing.** Found while fixing
the `writeFile` bug, because it is the same shape: `createProject` discarded
both of its `mkdirat` results and its two `writeFile` calls were `catch {}`.
An unwritable target therefore printed `created project at …`, exited 0, and
left no files behind. The mkdirs now propagate (EEXIST is still success) and
the writes are `try`, so `main()` reports
`zag: init failed in <dir>: <Error> (<ERRNO>)` and exits 1. The mkdirs also
replace two unchecked `@memcpy`s into 256-byte stack buffers with a
bounds-checked path, guarded by an up-front `dir.len > 250` check.

**5. The lexer's token buffer overflowed on real sources (found landing P1).**
`Lexer.tokens_buf` was `[4096]Token` and `addToken` wrote
`self.tokens_buf[self.tokens_len] = tok` with no bounds check, so any source
past roughly 600 dense lines aborted the compiler with
`index out of bounds: index 4096, len 4096` — a raw panic, no diagnostic, no
indication of which file. `lib/std/posix.zag` sat at ~85% of that cap, and the
P1 split pushed it over. A 1200-line user file reproduces it independently of
this plan, so it was a live bug, not a stress-test curiosity. The cap is now
`[16384]` (4×), and `addToken` prints
`error:<line>:<col>: source file has more than 16384 tokens (lexer limit)` and
exits 1 — following `Parser.expect`'s precedent for a parse-time hard stop.
The cost is stack (`Token` is ~32 bytes, so the field is ~512 KiB and the
`Lexer` is a stack local in `transpileEx` and in the whole-module import
expansion, which nests one per import level); an unbounded, heap-backed token
list is the real fix and the comment in `src/lexer/core.zig` points at it.
Regression test in `src/tests/lexer.zig`.

### Known Pre-Existing Bugs (not part of this plan)

- **A block with more than 256 statements panics the compiler.**
  `parseBlock` fills a `[256]` `stmts_buf` with the same unchecked
  `stmts_buf[stmt_count] = …` shape the lexer had. Unlike the token buffer
  this is not hit by real sources (256 statements in ONE block is unusual;
  a long file spreads them across functions), so it was left alone rather
  than silently enlarged — but it is the same bug class and should get the
  same treatment.
- **The whole-module barrel import `import std.{X}` does not resolve at
  all**, for any `X`: `import std.{read_file}` fails exactly like
  `import std.{Errno}`. Codegen emits `@import("std/mod.zig")`, and
  `materializeWalk` deliberately skips `mod.zag` (writing it would produce a
  single self-importing file that drags in every std module), so the mirror
  file never exists. `docs/manual/23-modules.md` documents the `§Barrels`
  form as supported, which makes this a documented-but-broken surface. The
  working spelling is the direct module path (`import std.errno.{Errno}`).

### Known Coverage Gap

`src/main.zig` ends with a `test "remap walker: …"` block that calls
`mkPath` / `writeSyntheticZagMap`, but the test module's root is
`src/tests.zig` and nothing in that graph imports `main.zig` — so the block
is **never compiled or run** by `zig build test`. It looks like coverage and
isn't. Importing `main.zig` into the test module is not the fix: it would drag
`toolchain.zig` and `build_options` into the test binary, which is exactly the
3–4× bloat `src/tests.zig` exists to avoid. The substance of that test is
covered by `src/tests/sys.zig` (nested `mkdirPath` + a `.zag.map` write/read
round-trip); the walker itself still needs a home inside the test graph.

The same limit applies to the failures added in the P4 slices:
`materializeStdlib` / `materializeWalk` propagation, the capture loops, and
`reportMaterializeFailure` all live in `main.zig`, so they are reachable only
by running the compiler as a subprocess. Their helpers (`sys.readSome`,
`sys.dirEntries`, `sys.openReadOnly`) are unit-tested; the end-to-end paths
are covered by the full `examples/run_all.sh` run plus the by-hand injections
listed in the Testing Strategy, not by an automated step. A `tests/` runner in
the SKIP-on-missing-fixture style of `fs_smoke.zig` is the natural home for
them.

The P1 tier split is the same story: `lib/std/posix.zag` is not in the
`zig build test` graph (it is Zag source, not Zig), so its correctness rests
on `examples/error-handling/posix_tier.zag` (10 `@[test]` blocks, now run by
`zig build example_tests` in CI) plus the full example suite, and on
`tests/scaffold.zig`'s parse-only check that the barrel still has its 30
imports. There is no compile-time link check that a `lib/std` consumer
actually handles every new `Result` — that is what the Zag compiler's "all
non-void values must be used" rule supplies instead, and why the migration
could not silently leave a call site behind.

**Remaining.** `zig build example_tests` now covers the whole catalog, so what
is left is narrower than it was:

- **`examples/sibling-tls` cannot be gated.** It is a lib-only project
  (`[lib] root = "src/lib.zag"`, no `src/main.zag`), so project-mode
  `zag test` errors with `no src/main.zag found`. It has no test-bearing file
  today, so discovery never selects it — but the day it gains a `fun test_*`
  or `@[test]`, the step would pick up the project and fail on that error
  rather than on a test. Either the project gains an entry point or project
  mode grows lib-only support.
- **A non-default `--prefix` breaks project mode only.** With the binary
  installed off `zig-out/bin`, `<exe>/../../lib/std` points outside the
  repository. File mode still resolves `./lib/std` from the build root;
  project mode needs `ZAG_HOME=<repo>` or the default prefix.
- **A fixture can still pass vacuously** if its tests print without a trailing
  newline: the gate is the exit code, not a parsed `N passed` count, so a
  fixture that silently ran zero cases would look green. That is the same
  reason `building.zag` (whose only `@[test]` is in a doc comment) is
  correctly not selected at all.
- **The audit's callee set is a judgement call, not a proof.** It covers the
  close/sync + transfer family plus `waitpid`/`dup2`/`lseek`/`ftruncate`, and
  excludes `futex_wait`, `execve`, and `mkdirat`-style calls for the reasons in
  `isAuditedDiscardCallee`. A discarding call to something outside the set (or
  a `catch {}` that swallows an error) is invisible to it; the gate raises the
  floor on the shapes that have actually caused bugs here, it does not make
  discards safe in general.

### Verified Language Constraints

Probed against the current compiler before designing. These are facts, not
assumptions, and they constrain the implementation:

| Capability | Verified behaviour |
|---|---|
| `Result(void, E)`, `Ok(undefined)`, `if let Err(_)` | works — available for close/sync/truncate-style ops |
| User struct with `impl` as the `Result` error payload | works — the basis of `Errno` |
| Enum with explicit discriminants (`Enoent = 2`) | works |
| Integer match patterns with `_` wildcard | works — the basis of `Errno.of` |
| Ignoring a non-void return | **compile error** ("all non-void values must be used") — makes the migration compiler-enforced |
| `enum_from_int` on a user enum with explicit discriminants | **unreliable** — returned the wrong variant. Do not use for `Errno.of` |
| Enum variant with a payload (`B(i32)`) | **unsupported** — hence the `{ kind, code }` struct |
| Struct literal inline inside `Err(Errno { … })` | **parse error** (`expected rparen, got '{'`) — hoist to a `let` binding first |
| Naming a user enum `E` | **collides** with the `Result` prelude's `E` global. Avoid `E` as a type name |
| `if let Err(e)` with `e` unused | **compile error** ("unused capture") — use `Err(_)` to discard the payload |
| `break` inside a `match` arm | targets the **enclosing loop**, not the match (this is what makes the `read_file` drain loop work) |
| `match` with more than 16 arms | **was a compiler ABORT** — `parseMatchExpr`'s `arm_buf` was a `[16]` indexed without a bounds check, so arm 17 ran off the end and killed the compiler with `index out of bounds` and no diagnostic. **Fixed** (see below) |
| Statement-position `match` whose arms ALL end in real statements | **was a compile error** — an arm only emits `break :<lbl>` when it carries the match's value, so an arm ending in an assignment or `return` leaves the label unused and zig rejects it with "unused block label". **Fixed** (see below) |
| Adding a new `lib/std` module | must be registered in `KNOWN_STD_MODULES` (`src/parser/core.zig`) or `import std.<name>` is **skipped silently** — the import line vanishes from the emitted zig and the failure surfaces much later as a zig "use of undeclared identifier". Not a bug, but a required step that is easy to miss |
| Calling an imported function whose name matches a method of the enclosing `impl` | **ambiguous reference** in the emitted zig — inside `impl File`, `close(fd)` matches both the container-scoped `File.close` method and the imported `std.posix` entry. Import it under an alias (`close as posix_close`) and use that spelling inside the impl |
| A `match` arm whose body is a bare `return` | **parse error** (`expected arrow, got ','`) — wrap the arm in braces: `Ok(v) => { return v; },` |
| A struct field whose type is a `pub const`-sized array (`parent: [PARENT_CAP]u8`) | works — including `undefined` initialization, `memcpy` into the field via a slice, and moving the struct out of a match arm |
| Comments inside a `struct` body (between fields) | **parse error** (`expected identifier`) — field docs must sit above the struct. Comments inside an `impl` body are fine |

The enum-payload, inline-struct-literal, `E`-name, and unused-capture items
are pre-existing codegen/parser limitations that this feature works around.
The two `match` items marked **Fixed** were repaired alongside P0 — see
[Companion Compiler Fixes](#companion-compiler-fixes-landed-with-p0).

### Risks And Tradeoffs

- **Blast radius.** 15 `lib/std` files import `std.posix`; `File` call sites
  concentrate in 5 files (53 sites). No example calls raw posix directly except
  through `std.concurrent.*`, so user-visible churn is small. The migration is
  compiler-checked: ignoring a `Result` is a hard error, so nothing can be left
  half-migrated silently.
- **`_ =` is the failure mode of the migration itself.** Making the discard
  compiler-checked but mechanically swallowed would recreate the bug class with
  more ceremony. Mitigated by the audit test in Testing Strategy step 5 and by
  making the failure policy visible at the call site — originally by naming
  panicking forms `*_or_panic`, superseded while landing by postfix `!`, which
  is even more local (the marker is on the line that fails, not in the callee).
- **`Result(void, E)` is load-bearing.** It works today, but if a future codegen
  change breaks it, every void-payload syscall must fall back to
  `Result(bool, E)`. That is a one-line change per function.
- **Two tiers invite tier confusion.** A developer may reach for `raw_*` just to
  avoid a `match`. Mitigated by documenting the raw tier as "for loops that
  already own their errno policy", and by `read_full`/`write_full` removing the
  need for raw access in the common case.
- **Errno detail is lost at the `fs` tier** by mapping to the 7-variant
  `std.error.Error`. Deliberate: `posix` keeps the exact code, `fs` gives a
  stable branch target. Callers needing `ENOSPC` specifically use
  `write_file` or the posix tier.
- **No fsync on build artifacts** means a crash mid-build can leave a truncated
  generated `.zig`. Acceptable — the next build regenerates it. Lockfiles and
  scaffolding are exempt.
- **`File` size** grows 4 → ~528 bytes. Accepted for now.
- **Sequencing cost.** P3–P4 touch the compiler broadly; landing them as
  separate commits keeps `git bisect` useful.

### Resolved Decisions

Decided during design review:

1. **posix API shape:** `Result`-default with a `raw_*` escape hatch. Not the
   additive `try_*` variant, because that leaves the unsafe tier as the default;
   not the two-step variant, because the shared helpers in P0 stop the bug class
   immediately anyway.
2. **`File` contract:** full rebuild — retain the parent path, `Result`-returning
   operations including `close`/`sync`, directory durability built in. (The
   plan's `*_or_panic` naming was superseded by postfix `!`, and the four
   constructor names collapsed into `File.open(path, mode)` — see the P2
   section.)
3. **Compiler scope:** full sweep with `src/sys.zig` and a new audit hook, not
   just the IO primitives.
4. **`Errno` representation:** `struct Errno { kind: ErrnoKind, code: isize }`.
   The enum gives an exhaustive `match` branch target; the `isize` preserves the
   exact kernel code for diagnostics when the errno is outside the named set.
5. **`close()` semantics:** `close()` is a checked close only (fast); the
   durable sequence is `close_durable()` = fsync + close + parent fsync, and
   `write_file` uses it. `File.open(_, FileMode.Create)` additionally marks
   the handle so the directory entry can be flushed — in the implementation the parent fsync
   step is gated on that `created` flag, so an existing file's close does not
   pay for a directory flush it does not need. A plain `close()` does not
   silently fsync. Closing an already-closed handle is `Ok(undefined)` (the
   postcondition already holds).
6. **`raw_*` visibility:** `pub`, documented as restricted to loops that own
   their errno policy, so `std.concurrent` and storage code can stay
   branch- and allocation-free.
7. **Audit hook:** included — a grep test over `lib/std/**` and `src/` that
   fails the build on an unnamed discard of a syscall result.

### Follow-Ups

Work identified while landing the `!` collapse and the memory-leak ledger,
recorded so it is not rediscovered. Each entry names the outcome, the reason
it was deferred, and where the code stands today.

#### 1. Cross-module method overloading — OPEN (largest item)

**Outcome wanted:** a static call from an importing module can resolve an
overloaded method on the imported type, so `File.open(path)` and
`File.open(path, mode)` can be one overload set and `FileMode` can become
optional again.

**Why it is not a one-liner:** overloading resolves against the declaring
type's `impl` table (`Codegen.prog.impls`), which a *calling* module does not
have. `staticTypeNameOf` (`src/codegen/core.zig`) answers "is this ident a
declared type?" from `prog.structs` / `prog.enums` / `prog.traits` — all
module-local. A stdlib type therefore fails the check, `resolved` stays
`null`, the call site emits the bare name, and the module emits the mangled
one (`open_str` / `open_str_FileMode`). Note `resolveOverloadedMethod`'s own
param is literally `receiver_type`, which is how the assumption is baked in.

**Sketch of the fix:** register imported modules' type + `impl` decls into a
side table when the imports loop resolves a path (`src/codegen/core.zig`, the
`__zag_imported_<i>` emit), and have `staticTypeNameOf` /
`resolveOverloadedMethod` consult it. The stdlib source is on disk at that
point (`lib/std/fs.zag`), but in project mode the *materialized* copy
(`build/gen/std/fs.zig`) is what the emitted zig imports, so the two views
must be kept consistent. Do not attempt this without adding a test that
compiles a two-module overload fixture.

**Interim contract:** do not overload a method that other modules call off
the type name. `File.open(path, mode)` is the worked example
(docs/manual/30 §"Across modules").

#### 2. Cross-module overload diagnostic — OPEN (small)

**Outcome wanted:** a call that *would* resolve in-module but cannot
cross-module reports the limitation, instead of the current outcome — a zig
error inside generated code (`struct 'std.fs.File' has no member named
'open'`) with no mention of overloading.

The information needed is available: the emitted module name is known to be
mangled (it contains `_` + a type fragment for a name that has >1 impl
method), and the call site is a static form. A check that the callee name
looks mangled while the call emits it bare would catch the case and can print
"`File.open` is overloaded in its declaring module and cannot be resolved
from `<this module>`; give it one signature or call a differently-named
method". Blocked on nothing; it is a diagnostics-only change.

#### 3. A grammar/spec pass for `!` — OPEN (small)

`docs/spec.md` §3.3 describes the error vocabulary in prose but its grammar
block still lists only `?` and `catch` as error forms. `!`
is a real postfix operator (`Expr.unwrap_op`, built by the postfix chain with
`!=` excluded), and `FileMode` is a real public enum. Both should appear in
the spec's grammar and type surface so `docs/manual/19` and the spec agree
end to end. The manual is already correct; the spec is the lagging artifact.

#### 4. Policy-suffixed identifier audit — OPEN (small, mechanical)

The `_or` / `*_or_panic` convention is retired (`read_file`, `write_file`,
`File.open(path, mode)`, `!`). A grep sweep for other identifiers that encode
a *failure policy* in the name — rather than the operation — would catch
stragglers and prevent the convention from creeping back. Candidates to
inspect: `try_*` prefixes, `*_or_default`, and any `*_checked` suffix. Scope
it to `lib/std` first; the compiler's own `src/sys.zig` deliberate-discard
helper names (`closeChecked`, `closeOnErrorPath`, `waitPidOrIgnore`) are
intentional and should be listed as exempt.

#### 5. Failure-policy conformance fixture — OPEN (small)

The `!` / `?` / `catch` / `match` policies are each documented and each
covered somewhere, but not by one fixture that runs all four against the
*same* call and asserts the four distinct outcomes (panic message, propagated
`Err`, fallback value, branch). `examples/error-handling/` is the home for
it. The value is regression-proofing the claim that a library needs only one
spelling per operation.

#### 6. Memory: `String` reclaim — LANDED, with one caveat

`String.deinit()` now exists (`lib/std/types/string.zag`), closing the gap
where a `read_file` result had no release path and the leak-check recipe could
never return to baseline in a file-reading program. It releases `cap` (the
exact amount `alloc_raw`/`realloc_raw` charged), then zeroes `len`/`cap` so a
second call is a no-op rather than an `munmap` of a released range — the same
shape `ArrayList.deinit` uses, including the `cap > 0` guard for a
`with_capacity(0)` String that never mapped.

**Caveat, now documented rather than fixed:** the receiver is `*String`, so the
binding must be `var`. `let s = read_file(p)!; s.deinit();` is a compile error
(`expected type '*T', found '*const T'`). Every reader of this API has to learn
that from the compiler today. A `deinit(self: *const String)` would be unsound
(it mutates), so the options are a `var`-only convention (current) or a
free-standing `String.release(&s)` form. Not worth changing until it bites
someone.

#### 7. Compile-time leak warning covers `alloc`/`alloc_raw` — LANDED

The warning used to fire only for `.new_expr`: `let buf = alloc(n)` with no
`free buf` produced nothing at all, and only the runtime ledger in `std.bench`
could see the leak. `src/codegen/escape.zig` now creates a site at the `.call`
node for `std.mem`'s owning-allocation family (`alloc`, `alloc_raw`) and
records which callee it was, so the diagnostic names the construct. Two
supporting rules were needed for that to be useful rather than noisy:

- **`release(p, cap)` is a discharge.** Argument 0 is the mapping the callee
  unmaps, so it is marked freed instead of escaping. Without it the raw tier's
  own documented pairing (`alloc_raw(n)` + `release(p, n)`) would read as a
  leak — a false positive on correct code.
- **`print` / `assert` are non-retaining.** They format or test the value and
  keep nothing. Under the old blanket "every call argument escapes" rule the
  overwhelmingly common leak shape — allocate, report something about the
  buffer, never free — was silently exempt. Both are compiler-dispatched
  builtins, so no user function can shadow them.

Verified: the whole 74-fixture example corpus plus the stdlib produce exactly
ONE warning, and it is the deliberate leak in `examples/memory/leak_check.zag`
(`test_a_real_leak_is_visible`, which now doubles as the warning's fixture).
12 new cases in `src/tests/codegen_escape.zig` pin both directions — the leak
verdicts and the hint text per family, and the no-false-positive cases
(`free`, `release`, `defer release`, `return`, user call, field store).

**Residual limit, by design:** the analysis is still conservative in the
"never cry wolf" direction. A buffer handed to any callee it cannot see into
counts as escaping, so the warning catches the never-touched shape, not every
leak — the runtime ledger remains the exact answer. Widening it further means
callee resolution (does this `consume` retain its argument?) which the walker
does not do. Related and also open: `{s}` on a `String` interpolates the struct
fields, not the contents (`String` has no `Display` impl), so the manual has to
tell readers to write `{s.as_str()}`.

#### 8. `docs/spec.md` drift around `String` and interpolation — OPEN (partly fixed)

Corrected while landing the memory work, because it was telling readers to
allocate a `String` the language cannot build:

- `new String("hello")` was the documented constructor. It does not compile
  (`new T(v)` is the allocator `create` path; `String` wants a single
  initializer and has none). Replaced with `String.from_str` /
  `String.with_capacity`.
- The method list advertised `push(c: char)`, `reserve(extra)`, and a
  `len`/`cap`-mutating surface. None exist; the list now matches the 18 real
  methods, including the new `deinit()`.
- The interpolation text described specifiers as a Python/Rust mini-language
  (`:x`, `:b`, `:o`, `:>N`, `:<N`, `:?`) converted via `to_string()`. Only
  zig's float precision form `{expr:.N}` survives; everything else is passed
  through verbatim and rejected by the zig formatter. `to_string()` does not
  exist. Text corrected; the mini-language is a *language* feature that would
  need implementing.

**Still open:** the `fmt.Writer` `String` API (`as_writer`, `with_writer`, the
writer-invalidation contract, and the `-Dref-check` step that was said to
enforce the writer's scope). None of it exists — `as_writer`, `with_writer`,
and `ref-check` have no occurrences in `src/`, `lib/`, or `tests/`. The spec
section now says so explicitly rather than describing it as current. Decide
whether to build it (there is real value in formatting into an owned buffer
without an intermediate allocation) or delete the remaining prose. Deleting is
the cheap option and does not rule out building it later.

#### 9. No move/ownership enforcement — `String` and `*T` alias on copy — OPEN (hazard)

Found while documenting the `String` lifecycle. Every Zag type is a fixed-size
value, so copying one copies its bytes. For an owning handle the "bytes" are
just the descriptor:

```
let s: String = String.from_str("hello");
var t: String = s;      # t.ptr == s.ptr, both valid, no move
t.deinit();             # releases the buffer s still points at
print("{s.as_str()}");  # SEGFAULT — use-after-free, no diagnostic
```

The same holds for `let q: *i32 = p;` — it aliases, and `free(p)` leaves `q`
dangling. `docs/spec.md` §5.2 and `docs/manual/07-types.md` claimed
"non-`Copy` types move; the source becomes uninitialized", and the spec
threaded a `-Downership-check` / `-Dleak-check` / `-Dref-check` flag family
through §5.7 and the manual that does not exist in `build.zig`. Both documents
now state the real behavior and the discipline instead.

**What actually guards anything today:** receiver mutability. `deinit` and
mutating methods take `*String`, so a `let` binding cannot be released through
(`expected type '*T', found '*const T'`). That forces `var` and nothing else —
two `var` bindings alias happily. Notably it does *not* catch the most likely
mistake, because the copy is what has to be mutable for the double-release to
compile.

**Options, cheapest first:**

1. Document only (done — manual 07, spec §5.2, and this entry).
2. Take `deinit(self: *const String)` and compare-and-clear: no. It mutates.
3. Make `String` a handle rather than a value — store the buffer behind a
   pointer and give the type a real identity — so copying still aliases but at
   least the aliasing is obvious at every site.
4. Implement the ownership analysis: track owning bindings, reject copies of
   them, and make `deinit`/`free` consume. This is the only option that makes
   the documented model true, and it is a compiler project (the escape
   analysis for leak warnings already walks `.let` bindings, so there is a
   starting point — but its scope is slice length, not ownership).

Until one of those lands, the rule for `lib/std` and examples is: one binding
owns a buffer; pass `*T` or a borrowed view to callees; release once.

#### Memory ledger: the landed contract (for reference)

Not a follow-up, but the decision the follow-ups above build on. The runtime
allocation ledger behind `std.bench.Counters.snapshot()` is charged in the
**primitives**, never at call sites, because a charge a caller must remember
is a charge that gets forgotten or applied twice:

| Construct | Charged | Discharged by |
|---|---|---|
| `new T(v)` (emit in `src/codegen/expr.zig`) | `@sizeOf(T)` | `free p` |
| `alloc(n)` → `alloc_raw` | `n` | `free buf` |
| `alloc_raw(n)` | `n` | `release(p, n)` |
| `realloc_raw(p, cap, n)` | `n - cap` | `release(p, cap)` at the end |
| containers / slice helpers | via the primitives | `deinit()` / `free` |
| `String` (incl. every `read_file` result) | `alloc_raw` / `realloc_raw` | `String.deinit()` (needs a `var` binding) |

`String.deinit()` landed with the follow-up above: the buffer is
`alloc_raw`-backed, so the ledger always reported it correctly, but until that
method existed there was no way to discharge it, and every `read_file` result
was process-exit-reclaim by construction.

The fix that made the rest true: `release` previously discharged nothing and
`realloc_raw` charged nothing, while `lib/std/strings/slices.zag` charged a
SECOND time on top of `alloc_raw` — so every container `deinit` left phantom
live bytes and every helper result read as a 2x leak. `Counters.snapshot()
.bytes_live` now returns to baseline exactly when everything is released,
which is what makes the comparison in `docs/manual/20-memory.md §"Checking
for leaks"` a usable assertion. The discharge saturates at zero so a
size-mismatched release can never wrap to a huge `usize` and read as an
enormous leak. Verified by `examples/memory/leak_check.zag` (9 `@[test]`
rows) and by `zig build example_tests`.

### Open Questions

None blocking. Items to revisit during implementation:

- **Final named-errno set.** The list starts at roughly 30 codes covering what
  `lib/std` actually branches on. If diagnostics for other errnos prove
  important, extend `ErrnoKind`; the `{ kind, code }` shape means no caller
  changes are required.
- **Whether `File.parent` stays embedded.** If the 528-byte handle becomes a
  measurable cost in a storage-engine workload, move the parent path behind a
  pointer and take the allocation.
- **Duplication between `std.errno` and `src/sys.zig`.** Both need an
  errno-to-name mapping and a sign-bit test, in different languages. Extracting
  a shared generated table is possible but adds a build step; deferred until the
  duplication is large enough to justify it.
- **`std.error.Context` integration.** The tier boundaries now make this
  tractable (each layer could attach context), but it is a separate feature.
