"""Zag LLDB assistant — maps zig source locations back to zag source files.

Load in .lldbinit or manually:
    (lldb) command script import /path/to/tools/zag_lldb.py

After loading, `thread backtrace` is decorated with zag file:line:col.
Set breakpoints on zag files: `zag-break src/main.zag:22`

The script reads .zag.map files from build/gen/ (tab-separated format):
    zig_line  zag_line  zag_col  symbol  source_file
"""

import lldb
import os
import re
from collections import defaultdict


# ---------------------------------------------------------------------------
# Map file loading
# ---------------------------------------------------------------------------

MAP_ENTRIES = []          # list of (zig_file, zig_line, zag_line, zag_col, symbol, source_file)
ZAG_TO_ZIG = {}           # (source_file, zag_line) -> set of (zig_file, zig_line)
MAP_DIR = "build/gen"
MAP_LOADED = False


def load_map_files(map_dir=MAP_DIR):
    """Load all .zag.map files from map_dir and build lookup tables."""
    global MAP_ENTRIES, ZAG_TO_ZIG, MAP_DIR, MAP_LOADED
    MAP_ENTRIES.clear()
    ZAG_TO_ZIG.clear()
    MAP_DIR = map_dir
    MAP_LOADED = True

    if not os.path.isdir(map_dir):
        print("[zag] map directory not found: {}".format(map_dir))
        return

    for fname in sorted(os.listdir(map_dir)):
        if not fname.endswith(".zag.map"):
            continue
        path = os.path.join(map_dir, fname)
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
# Frame filter — decorates backtrace lines with zag locations
# ---------------------------------------------------------------------------

def zag_resolve_location(frame):
    """Resolve an LLDB frame to a zag source location. Returns (file, line, col, symbol) or None."""
    line_entry = frame.GetLineEntry()
    if not line_entry.IsValid():
        return None
    filename = str(line_entry.GetFileSpec().GetFilename() or "")
    dirname = str(line_entry.GetFileSpec().GetDirectory() or "")
    # Only remap files under build/gen/
    if not dirname.endswith("/gen") and not dirname.endswith("\\gen"):
        return None
    if not os.path.basename(dirname) == "gen":
        return None

    zig_line = line_entry.GetLine()
    lookup = lookup_zig(filename, zig_line)
    if lookup is None:
        return None
    source_file, zag_line, zag_col, symbol = lookup
    return source_file, zag_line, zag_col, symbol


# ---------------------------------------------------------------------------
# LLDB commands
# ---------------------------------------------------------------------------

class ZagBreakCommand:
    """Set a breakpoint using zag source file and line."""

    def __init__(self, debugger, _unused):
        pass

    def __call__(self, debugger, command, exe_ctx, result):
        if not MAP_LOADED:
            load_map_files()

        args = command.strip()
        if not args:
            print("Usage: zag-break <source.zag>:<line>", file=result)
            return

        m = re.match(r'^(.+?):(\d+)', args)
        if not m:
            print("[zag] expected FILE.zag:LINE, got '{}'".format(args), file=result)
            return

        zag_file = m.group(1).strip()
        try:
            zag_line = int(m.group(2))
        except ValueError:
            print("[zag] invalid line number: {}".format(m.group(2)), file=result)
            return

        key = (zag_file, zag_line)
        locations = ZAG_TO_ZIG.get(key)
        if not locations:
            print("[zag] no map entry for {}:{}".format(zag_file, zag_line), file=result)
            return

        target = debugger.GetSelectedTarget()
        if not target:
            print("[zag] no target selected", file=result)
            return

        for zig_file, zig_line in sorted(locations):
            bp_path = os.path.join(MAP_DIR, zig_file)
            bp = target.BreakpointCreateByLocation(bp_path, zig_line)
            print("[zag] +breakpoint {}: {}:{} (zig {}:{})".format(
                bp.GetID(), zag_file, zag_line, zig_file, zig_line), file=result)


class ZagBacktraceCommand:
    """Print backtrace with zag source locations."""

    def __init__(self, debugger, _unused):
        pass

    def __call__(self, debugger, command, exe_ctx, result):
        if not MAP_LOADED:
            load_map_files()

        target = debugger.GetSelectedTarget()
        if not target:
            print("no target", file=result)
            return

        process = target.GetProcess()
        if not process:
            print("no process", file=result)
            return

        thread = process.GetSelectedThread()
        if not thread:
            print("no thread", file=result)
            return

        for i, frame in enumerate(thread.frames):
            frame_info = "[{}] {}".format(i, str(frame.GetFunctionName() or "???"))
            loc = zag_resolve_location(frame)
            if loc:
                sf, sl, sc, sym = loc
                frame_info += "  -> {}:{}:{} in {}".format(sf, sl, sc, sym)
            print(frame_info, file=result)


def zag_print_frame(debugger, exe_ctx, result):
    """Overrides the default frame output to show zag locations."""
    frame = exe_ctx.GetFrame()
    if frame and frame.IsValid():
        loc = zag_resolve_location(frame)
        if loc:
            sf, sl, sc, _ = loc
            print("[zag] {}:{}:{}".format(sf, sl, sc), file=result)


# ---------------------------------------------------------------------------
# Initialize on import
# ---------------------------------------------------------------------------

def __lldb_init_module(debugger, internal_dict):
    """LLDB calls this when the script is loaded via `command script import`."""
    if not MAP_LOADED:
        load_map_files()

    debugger.HandleCommand("command script add -f zag_lldb.zag_print_frame zag-where")
    debugger.HandleCommand("command script add -f zag_lldb.ZagBreakCommand zag-break")
    debugger.HandleCommand("command script add -f zag_lldb.ZagBacktraceCommand zag-bt")

    # Register a stop-hook that shows zag location on each stop
    def zag_stop_hook(frame, bp_loc, dict):
        if frame and frame.IsValid():
            loc = zag_resolve_location(frame)
            if loc:
                sf, sl, sc, _ = loc
                print("[stop] {}:{}:{}".format(sf, sl, sc))
        return None

    print("[zag] LLDB integration ready. Commands: zag-break, zag-bt, zag-where")
