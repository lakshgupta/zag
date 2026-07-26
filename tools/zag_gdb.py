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
            frame = frame.inferior_frame()
            sal = frame.find_sal()
            if sal is None or sal.symtab is None:
                yield frame
                continue

            filename = sal.symtab.fullname()
            if filename is None:
                yield frame
                continue

            # Only remap files under build/gen/
            fn = os.path.basename(filename)
            parent = os.path.basename(os.path.dirname(filename))
            if parent != "gen":
                yield frame
                continue

            lookup = lookup_zig(fn, sal.line)
            if lookup is None:
                yield frame
                continue

            source_file, zag_line, zag_col, symbol = lookup
            # Build a new sal with the zag source location
            try:
                symtab = gdb.lookup_global_symbol(source_file)
            except Exception:
                symtab = None
            # Store the zag location for the frame decorator
            frame._zag_file = source_file
            frame._zag_line = zag_line
            frame._zag_col = zag_col
            frame._zag_symbol = symbol
            yield frame


class ZagFrameDecorator:
    """Wraps a frame to show zag file:line:col in backtrace."""

    def __init__(self, frame):
        self._frame = frame
        zag_file = getattr(frame, "_zag_file", None)
        zag_line = getattr(frame, "_zag_line", None)
        zag_col = getattr(frame, "_zag_col", None)
        self._zag_file = zag_file
        self._zag_line = zag_line
        self._zag_col = zag_col

    def function(self):
        return self._frame.function()

    def address(self):
        return self._frame.address()

    def filename(self):
        if self._zag_file:
            return self._zag_file
        sal = self._frame.find_sal()
        if sal and sal.symtab:
            return sal.symtab.fullname()
        return None

    def line(self):
        if self._zag_line:
            return int(self._zag_line)
        sal = self._frame.find_sal()
        return sal.line if sal else 0

    def frame_args(self):
        return self._frame.frame_args()

    def frame_locals(self):
        return self._frame.frame_locals()

    def inferior_frame(self):
        return self._frame


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
