#!/usr/bin/env bash
# build.sh — build the Zag compiler and name the binary for the current platform
#
# Usage:
#   ./scripts/build.sh               # debug build
#   ./scripts/build.sh --release     # release build
#   ./scripts/build.sh --clean       # clean + debug build
#   ./scripts/build.sh --clean --release
#
# Environment variables:
#   ZAG_BUILD_CMD      Build command (default: zig build)
#   ZAG_CLEAN_CMD      Clean command (default: zig build clean)
#   ZAG_BUILD_OUT      Build output directory (default: zig-out/bin)
#   ZAG_RELEASE_FLAGS  Extra flags for --release (default: -Doptimize=ReleaseFast)

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

ZAG_BUILD_CMD="${ZAG_BUILD_CMD:-zig build}"
ZAG_CLEAN_CMD="${ZAG_CLEAN_CMD:-zig build clean}"
ZAG_BUILD_OUT="${ZAG_BUILD_OUT:-zig-out/bin}"
ZAG_RELEASE_FLAGS="${ZAG_RELEASE_FLAGS:--Doptimize=ReleaseFast}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CLEAN=0
RELEASE=0

# ── Helpers ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "  ${CYAN}→${NC} $*"; }
success() { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC} $*"; }
error()   { echo -e "  ${RED}✗${NC} $*" >&2; }

usage() {
    cat <<HELP
Usage: build.sh [flags]

Build the Zag compiler and name the binary for the current platform
so that other scripts (package.sh, install-local.sh, run_all.sh) can find it.

Flags:
  --release    Build in release mode (appends ZAG_RELEASE_FLAGS)
  --clean      Clean build artifacts before building
  --help       Show this help message

Environment:
  ZAG_BUILD_CMD      Build command (default: zig build)
  ZAG_CLEAN_CMD      Clean command (default: zig build clean)
  ZAG_BUILD_OUT      Build output directory (default: zig-out/bin)
  ZAG_RELEASE_FLAGS  Extra flags for --release (default: -Doptimize=ReleaseFast)
HELP
    exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean)   CLEAN=1 ;;
        --release) RELEASE=1 ;;
        --help)    usage ;;
        *)         ;;
    esac
    shift
done

# ── Platform detection ───────────────────────────────────────────────────────

detect_os_arch() {
    case "$(uname -s)" in
        Linux)  OS="linux";  SUFFIX="" ;;
        Darwin) OS="darwin"; SUFFIX="" ;;
        *_NT-*) OS="windows"; SUFFIX=".exe" ;;
        MINGW*) OS="windows"; SUFFIX=".exe" ;;
        MSYS*)  OS="windows"; SUFFIX=".exe" ;;
        *)      OS="linux";  SUFFIX="" ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)   ARCH="x86_64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        *)              ARCH="x86_64" ;;
    esac
}

detect_os_arch

# ── Pre-flight ───────────────────────────────────────────────────────────────

if ! command -v zig &>/dev/null; then
    error "zig not found on PATH"
    echo ""
    echo "  Install Zig from https://ziglang.org/download/"
    echo ""
    exit 1
fi

# ── Build ────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}═══ Zag Build ═══${NC}"
echo ""
echo -e "  OS/Arch:   ${OS}-${ARCH}"

BUILD_CMD="$ZAG_BUILD_CMD"
[[ $RELEASE -eq 1 ]] && BUILD_CMD="$BUILD_CMD $ZAG_RELEASE_FLAGS"

# Clean
if [[ $CLEAN -eq 1 ]]; then
    info "Cleaning..."
    if (cd "$REPO_ROOT" && eval "$ZAG_CLEAN_CMD"); then
        success "Clean complete"
    else
        warn "Clean command failed (non-fatal) — continuing with build"
    fi
fi

# Build
info "Building: $BUILD_CMD"
echo ""

(cd "$REPO_ROOT" && eval "$BUILD_CMD")

echo ""
success "Build complete"

# ── Platform-name the binary ─────────────────────────────────────────────────

SRC="${REPO_ROOT}/${ZAG_BUILD_OUT%/}/zag${SUFFIX}"
DST="${REPO_ROOT}/${ZAG_BUILD_OUT%/}/zag-${OS}-${ARCH}${SUFFIX}"

if [[ ! -f "$SRC" ]]; then
    error "Built binary not found at $SRC"
    echo ""
    echo "  Expected the build to produce: $SRC"
    echo "  Override with: ZAG_BUILD_OUT=<dir> ./scripts/build.sh"
    echo ""
    exit 1
fi

info "Naming binary for ${OS}-${ARCH}"
cp "$SRC" "$DST"
chmod +x "$DST"
success "${ZAG_BUILD_OUT%/}/zag-${OS}-${ARCH}${SUFFIX}"

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}Build successful!${NC}"
echo ""
echo "  Binary: $DST"
echo ""
echo "  Next steps:"
echo "    ./scripts/install-local.sh   # install to ~/.zag/bin/"
echo "    ./scripts/package.sh 0.1.0   # package for distribution"
echo "    ./examples/run_all.sh         # run the test harness"
echo ""
