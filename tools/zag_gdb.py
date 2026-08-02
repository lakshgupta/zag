"""Zag GDB assistant — maps zig source locations back to zag source files.

Load in .gdbinit or via `source tools/zag_gdb.py`:
    (gdb) source /path/to/tools/zag_gdb.py

After loading, `backtrace` shows zag file:line:col instead of zig paths.
Set breakpoints on zag files: `zag-break src/main.zag:22`

The script reads .zag.map files from build/gen/ (tab-separated format):
    zig_line  zag_line  zag_col  symbol  source_file
"""

import gdb
import os
import struct
import re
from collections import defaultdict


# ---------------------------------------------------------------------------
# Map file loading
# ---------------------------------------------------------------------------

MAP_ENTRIES = []          # list of (zig_file, zig_line, zag_line, zag_col, symbol, source_file)
ZAG_TO_ZIG = {}           # (source_file, zag_line) -> set of (zig_file, zig_line)
MAP_DIR = "build/gen"


def load_map_files(map_dir=MAP_DIR):
    """Load all .zag.map files from map_dir and build lookup tables."""
    global MAP_ENTRIES, ZAG_TO_ZIG, MAP_DIR
    MAP_ENTRIES.clear()
    ZAG_TO_ZIG.clear()
    MAP_DIR = map_dir

    if not os.path.isdir(map_dir):
        print("[zag] map directory not found: {}".format(map_dir))
        return

    for fname in sorted(os.listdir(map_dir)):
        if not fname.endswith(".zag.map"):
            continue
        path = os.path.join(map_dir, fname)
        # Derive zig file: main.zag.map -> main.zig
        zig_file = fname[:-8] + ".zig"

        with open(path, "r") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t")
                if len(parts) < 5:
                    continue
                try:
                    entry = (
                        zig_file,
                        int(parts[0]),   # zig_line
                        int(parts[1]),   # zag_line
                        int(parts[2]),   # zag_col
                        parts[3],        # symbol
                        parts[4],        # source_file
                    )
                except (ValueError, IndexError):
                    continue
                MAP_ENTRIES.append(entry)
                key = (entry[5], entry[2])  # (source_file, zag_line)
                ZAG_TO_ZIG.setdefault(key, set()).add((entry[0], entry[1]))

    print("[zag] loaded {} map entries from {}".format(len(MAP_ENTRIES), map_dir))


def lookup_zig(zig_file, zig_line):
    """Given a zig file and line, return (source_file, zag_line, zag_col, symbol) or None."""
    # Binary search: entries are sorted by load order, not by zig_line.
    # For a small number of entries, linear scan is fine.
    best = None
    for entry in MAP_ENTRIES:
        ef = entry[0]
        if ef != zig_file:
            continue
        el = entry[1]
        if el <= zig_line:
            if best is None or el > best[1]:
                best = entry
    if best:
        return best[5], best[2], best[3], best[4]
    return None


def lookup_zig_by_symbol(symbol):
    """Given a zig function name (e.g. 'main.sum'), return the first
    (source_file, zag_line, zag_col, zag_symbol) map entry whose
    symbol matches (suffix match after the module prefix). gdb 15
    cannot resolve the user module's addresses to file:line (a
    gdb/zig DWARF5 interop quirk — the preamble helper functions
    resolve, the user functions do not), so the frame filter falls
    back to function-name matching: the zag fn name 'sum' appears in
    the .zag.map symbol column, and the entry's zag_line is the fn's
    first statement — close enough to show the right source line in
    backtraces.
    """
    for entry in MAP_ENTRIES:
        sym = entry[4]
        if sym == symbol:
            return entry[5], entry[2], entry[3], entry[4]
        # 'main.sum' matches entry symbol 'sum'.
        if symbol.endswith("." + sym) or symbol == sym:
            return entry[5], entry[2], entry[3], entry[4]
    return None


# ---------------------------------------------------------------------------
# Frame filter — replaces zig paths in backtrace output
# ---------------------------------------------------------------------------

class ZagFrameFilter:
    """GDB frame filter that maps zig source locations to zag sources."""

    def __init__(self):
        self.name = "zag"
        self.priority = 100
        self.enabled = True

    def filter(self, frame_iter):
        for frame in frame_iter:
            # Unwrap to a raw gdb.Frame. gdb 12-14 pass gdb.Frame
            # objects; gdb 15 passes FrameDecorator WRAPPERS whose
            # .inferior_frame() returns the raw frame (and whose
            # base implementation raises AttributeError when its
            # wrapped frame is already raw). Catch everything — a
            # filter failure must never break the backtrace.
            raw = None
            try:
                raw = frame.inferior_frame()
            except Exception:
                raw = frame
            if raw is None:
                yield frame
                continue

            # Resolve (file, line): find_sal on raw frames, or the
            # decorator accessors when find_sal is unavailable.
            filename = None
            line = 0
            sal = None
            try:
                sal = raw.find_sal()
            except Exception:
                sal = None
            if sal is not None and sal.symtab is not None and sal.symtab.fullname() is not None:
                filename = sal.symtab.fullname()
                line = sal.line
            else:
                try:
                    filename = raw.filename()
                    line = raw.line()
                except Exception:
                    filename = None
            lookup = None
            if filename is not None:
                # Only remap files under build/gen/
                fn = os.path.basename(filename)
                parent = os.path.basename(os.path.dirname(filename))
                if parent == "gen":
                    lookup = lookup_zig(fn, line)
            if lookup is None:
                # gdb 15 cannot resolve the user module's frames to
                # file:line (DWARF5 interop quirk) — fall back to
                # function-name mapping via the .zag.map symbol column.
                try:
                    fname = frame.function()
                except Exception:
                    fname = None
                if fname:
                    lookup = lookup_zig_by_symbol(fname)
            if lookup is None:
                yield frame
                continue

            source_file, zag_line, zag_col, symbol = lookup
            # Yield a decorated frame directly — gdb 15 applies the
            # filter's yielded decorators to the backtrace (a separate
            # decorator entry in frame_filters is silently ignored).
            yield ZagFrameDecorator(frame, source_file, zag_line, zag_col)


class ZagFrameDecorator(gdb.FrameDecorator.FrameDecorator):
    """Wraps a frame to show zag file:line:col in backtrace (gdb 15:
    decorators must subclass gdb.FrameDecorator.FrameDecorator and be
    yielded from a frame filter — plain duck-typed wrappers registered
    as separate 'frame_filters' entries are silently ignored)."""

    def __init__(self, frame, zag_file=None, zag_line=None, zag_col=None):
        super(ZagFrameDecorator, self).__init__(frame)
        self._zag_file = zag_file
        self._zag_line = zag_line
        self._zag_col = zag_col

    def filename(self):
        if self._zag_file:
            return self._zag_file
        return super(ZagFrameDecorator, self).filename()

    def line(self):
        if self._zag_line:
            return int(self._zag_line)
        return super(ZagFrameDecorator, self).line()


def zag_frame_decorator(frames):
    """Decorate each frame in the iterator with zag location info."""
    for frame in frames:
        if hasattr(frame, "_zag_file") and frame._zag_file:
            yield ZagFrameDecorator(frame)
        else:
            yield frame


# ---------------------------------------------------------------------------
# Command: zag-break — set breakpoint on zag source
# ---------------------------------------------------------------------------

class ZagBreakCommand(gdb.Command):
    """Set a breakpoint using zag source file and line.

    Usage: zag-break <source.zag>:<line>
           zag-break <source.zag>:<line> if condition
    """

    def __init__(self):
        super(ZagBreakCommand, self).__init__("zag-break", gdb.COMMAND_BREAKPOINTS)
        self._re = re.compile(r'^(.+?):(\d+)')

    def invoke(self, arg, from_tty):
        arg = arg.strip()
        if not arg:
            print("Usage: zag-break <source.zag>:<line>")
            return

        m = self._re.match(arg)
        if not m:
            print("[zag] expected FILE.zag:LINE, got '{}'".format(arg))
            return

        zag_file = m.group(1).strip()
        try:
            zag_line = int(m.group(2))
        except ValueError:
            print("[zag] invalid line number: {}".format(m.group(2)))
            return

        # Look up all zig locations for this zag file:line
        key = (zag_file, zag_line)
        locations = ZAG_TO_ZIG.get(key)
        if not locations:
            print("[zag] no map entry for {}:{}".format(zag_file, zag_line))
            return

        for zig_file, zig_line in sorted(locations):
            bp_path = os.path.join(MAP_DIR, zig_file)
            cmd = "break {}:{}".format(bp_path, zig_line)
            print("[zag] " + cmd)
            gdb.execute(cmd)


class ZagListCommand(gdb.Command):
    """List zag source at the current frame's zag location."""

    def __init__(self):
        super(ZagListCommand, self).__init__("zag-list", gdb.COMMAND_FILES)

    def invoke(self, arg, from_tty):
        try:
            frame = gdb.selected_frame()
        except gdb.error:
            print("[zag] no frame selected")
            return

        zag_file = getattr(frame, "_zag_file", None)
        zag_line = getattr(frame, "_zag_line", None)
        if not zag_file or not zag_line:
            print("[zag] current frame has no zag mapping")
            return

        # Show 10 lines around the zag location
        start = max(1, int(zag_line) - 5)
        end = int(zag_line) + 5
        print("[zag] {}:{}".format(zag_file, zag_line))
        try:
            with open(zag_file, "r") as f:
                for i, line in enumerate(f, 1):
                    if i < start:
                        continue
                    if i > end:
                        break
                    marker = ">" if i == int(zag_line) else " "
                    sys.stdout.write("{}{:4d}  {}".format(marker, i, line))
        except IOError as e:
            print("[zag] cannot read {}: {}".format(zag_file, e))


# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

def init():
    """Initialize the zag GDB integration."""
    if not MAP_ENTRIES:
        load_map_files()

    # Register frame filter
    try:
        gdb.current_progspace().frame_filters[ZagFrameFilter().name] = ZagFrameFilter()
    except Exception:
        pass

    # Install frame decorator at the top of the filter chain
    existing = gdb.frame_filters.get("zag")
    if existing is None:
        try:
            # Register directly — the decorator wraps ALL frames
            gdb.frame_filters["zag_decorate"] = zag_frame_decorator
        except Exception:
            pass

    # Register commands
    try:
        ZagBreakCommand()
    except Exception:
        pass  # already registered
    try:
        ZagListCommand()
    except Exception:
        pass


# Try running init() on import
try:
    init()
except Exception as e:
    print("[zag] init warning: {}".format(e))


# ---------------------------------------------------------------------------
# Convenience: also provide a zag-backtrace command
# ---------------------------------------------------------------------------
class ZagBacktraceCommand(gdb.Command):
    """Print backtrace with zag source locations."""

    def __init__(self):
        super(ZagBacktraceCommand, self).__init__("zag-bt", gdb.COMMAND_STACK)

    def invoke(self, arg, from_tty):
        load_map_files()
        try:
            gdb.execute("backtrace " + arg.strip())
        except Exception:
            pass

try:
    ZagBacktraceCommand()
except Exception:
    pass


# ---------------------------------------------------------------------------
# zag-addr — resolve a .zag line to a binary address via the DWARF5
# line table (gdb 15 cannot resolve the user module's file:line, so
# the tool parses .debug_line itself and emits `break *ADDRESS`).
# ---------------------------------------------------------------------------

import subprocess


def _read_line_table(path):
    """Resolve (file basename, line) -> address using `readelf
    --debug-dump=decodedline` (binutils). Parsing the DWARF5 line
    program by hand is fragile; readelf's decoded text form is
    stable: file-header lines '  /abs/path/file.zig:' followed by
    rows '  main.zig  <line> 0x<addr>'. Returns
    {file_basename: [(line, address), ...]} (first/lowest address
    per line).
    """
    try:
        out = subprocess.run(
            ["readelf", "--debug-dump=decodedline", path],
            capture_output=True, text=True, timeout=30,
        ).stdout
    except Exception:
        return {}
    best = {}
    for ln in out.splitlines():
        parts = ln.split()
        if len(parts) < 3:
            continue
        fname = parts[0]
        if ":" in fname or not fname.endswith((".zig", ".zag")):
            continue
        try:
            lineno = int(parts[1])
            addr = int(parts[2], 16)
        except ValueError:
            continue
        key = (fname, lineno)
        if key not in best or addr < best[key]:
            best[key] = addr
    tables = {}
    for (fname, lineno), addr in best.items():
        tables.setdefault(fname, []).append((lineno, addr))
    for rows in tables.values():
        rows.sort()
    return tables


_LINE_TABLES = {}


def _line_table_for_exe():
    try:
        path = gdb.current_progspace().filename
    except Exception:
        return {}
    if path not in _LINE_TABLES:
        _LINE_TABLES[path] = _read_line_table(path)
    return _LINE_TABLES[path]


class ZagAddrCommand(gdb.Command):
    """Break at the address of a zag source line.

    Usage: zag-addr <source.zag>:<line>

    Resolves the zag line to a generated-zig line via the .zag.map,
    then to a binary ADDRESS via the DWARF5 line table (parsed
    directly — gdb 15 cannot resolve the user module's file:line),
    then sets `break *ADDRESS`.
    """

    def __init__(self):
        super(ZagAddrCommand, self).__init__("zag-addr", gdb.COMMAND_BREAKPOINTS)
        self._re = __import__("re").compile(r'^(.+?):(\d+)')

    def invoke(self, arg, from_tty):
        arg = arg.strip()
        m = self._re.match(arg)
        if not m:
            print("Usage: zag-addr <source.zag>:<line>")
            return
        zag_file = m.group(1).strip()
        zag_line = int(m.group(2))
        locs = ZAG_TO_ZIG.get((zag_file, zag_line))
        if not locs:
            print("[zag] no map entry for {}:{}".format(zag_file, zag_line))
            return
        tables = _line_table_for_exe()
        for (zig_file, zig_line) in sorted(locs):
            rows = tables.get(zig_file)
            if not rows:
                continue
            addr = None
            for (ln, a) in rows:
                if ln == zig_line:
                    addr = a
                    break
                if ln > zig_line:
                    break
            if addr:
                cmd = "break *0x{:x}".format(addr)
                print("[zag] " + cmd)
                gdb.execute(cmd)
                return
        print("[zag] no address found for {}:{} (is the binary built with debug info?)".format(zag_file, zag_line))


try:
    ZagAddrCommand()
except Exception:
    pass
