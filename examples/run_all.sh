#!/usr/bin/env bash
##
## run_all.sh — Test harness for Zag examples
##
## Discovers all .zag files under the examples/ directory, runs them
## through the Zag compiler, and reports pass/fail results.
##
## Usage:
##   ./run_all.sh              # run all examples
##   ./run_all.sh --build       # build from source, then run
##   ./run_all.sh --clean --build # clean, then build, then run
##   ./run_all.sh --release --build # release-mode build, then run
##   ./run_all.sh --check       # compile-check only (zag check)
##   ./run_all.sh --verbose     # show per-file output
##   ./run_all.sh basics/       # run only a specific category
##
## Environment variables:
##   ZAG_BIN        Path to the zag binary (auto-detected if not set)
##   ZAG_BUILD_CMD  Command to build the compiler (default: zig build)
##   ZAG_CLEAN_CMD  Command to clean build artifacts (default: zig build clean)
##   ZAG_BUILD_OUT  Directory containing built binaries
##                  (default: zig-out/bin)
##   ZAG_RELEASE_FLAGS  Extra flags appended for release builds
##                      (default: -Doptimize=ReleaseFast)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$PROJECT_ROOT"
ZAG_BIN="${ZAG_BIN:-}"   # empty = auto-detect
ZAG_BUILD_CMD="${ZAG_BUILD_CMD:-zig build}"
ZAG_CLEAN_CMD="${ZAG_CLEAN_CMD:-zig build clean}"
ZAG_RELEASE_FLAGS="${ZAG_RELEASE_FLAGS:--Doptimize=ReleaseFast}"
ZAG_BUILD_OUT="${ZAG_BUILD_OUT:-zig-out/bin}"
MODE="run"       # run | check
VERBOSE=0
BUILD=0
CLEAN=0
RELEASE=0
FILTER=""

# ── Parse args ───────────────────────────────────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        --build)    BUILD=1 ;;
        --clean)    CLEAN=1 ;;
        --release)  RELEASE=1 ;;
        --check)    MODE="check" ;;
        --verbose)  VERBOSE=1 ;;
        -h|--help)
            echo "Usage: $0 [--clean] [--build] [--release] [--check] [--verbose] [<category>]"
            echo ""
            echo "  --clean       Clean build artifacts before building"
            echo "  --build       Build the compiler from source before testing"
            echo "  --release     Build in release mode (appends -Doptimize=ReleaseFast)"
            echo "  --check       Compile-check only (zag check), don't run"
            echo "  --verbose     Show per-file compiler output"
            echo "  <category>    Run only examples in the given subdirectory"
            echo ""
            echo "  ZAG_BIN        Path to zag binary (auto-detected if not set)"
            echo "  ZAG_BUILD_CMD  Build command (default: zig build)"
            echo "  ZAG_CLEAN_CMD  Clean command (default: zig build clean)"
            echo "  ZAG_RELEASE_FLAGS  Extra flags for --release (default: -Doptimize=ReleaseFast)"
            echo "  ZAG_BUILD_OUT  Build output dir (default: zig-out/bin)"
            exit 0
            ;;
        *)  FILTER="$arg" ;;
    esac
done

# ── Colours ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # no colour

# ── Helpers ──────────────────────────────────────────────────────────────────

info()    { echo -e "  ${CYAN}→${NC} $*"; }
success() { echo -e "  ${GREEN}✓${NC} $*"; }
warn()    { echo -e "  ${YELLOW}⚠${NC} $*"; }
error()   { echo -e "  ${RED}✗${NC} $*"; }

# ── Platform detection ───────────────────────────────────────────────────────

detect_platform() {
    local os arch
    case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
        linux)   os="linux" ;;
        darwin)  os="darwin" ;;
        mingw*|msys*|cygwin*) os="windows" ;;
        *)       os="linux" ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  arch="x86_64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)             arch="x86_64" ;;
    esac
    local suffix=""
    [ "$os" = "windows" ] && suffix=".exe"
    echo "${os}" "${arch}" "${suffix}"
}

# ── Build step ───────────────────────────────────────────────────────────────

if [[ $BUILD -eq 1 ]]; then
    echo ""
    echo -e "${BOLD}${CYAN}═══ Building Zag Compiler ═══${NC}"
    echo ""

    # ── Release-mode flags ──────────────────────────────────────────────────
    if [[ $RELEASE -eq 1 ]]; then
        ZAG_BUILD_CMD="${ZAG_BUILD_CMD} ${ZAG_RELEASE_FLAGS}"
        info "Release mode: ${ZAG_RELEASE_FLAGS}"
        echo ""
    fi

    # ── Clean step ───────────────────────────────────────────────────────────
    if [[ $CLEAN -eq 1 ]]; then
        info "Clean command: ${ZAG_CLEAN_CMD}"
        echo ""
        if (cd "$REPO_ROOT" && eval "$ZAG_CLEAN_CMD"); then
            success "Clean complete"
        else
            warn "Clean command failed (non-fatal) — continuing with build"
        fi
        echo ""
    fi

    info "Build command: ${ZAG_BUILD_CMD}"
    info "Build root:    ${REPO_ROOT}"
    echo ""

    (cd "$REPO_ROOT" && eval "$ZAG_BUILD_CMD") || {
        echo ""
        error "Build failed."
        echo ""
        echo "  Set ZAG_BUILD_CMD to override the build command:"
        echo "    ZAG_BUILD_CMD='make' ./run_all.sh --build"
        exit 1
    }

    info "Placing built binary into zig-out/bin/..."
    read -r OS ARCH SUFFIX <<< "$(detect_platform)"
    local_src="${REPO_ROOT}/${ZAG_BUILD_OUT%/}/zag${SUFFIX}"

    if [ -f "$local_src" ]; then
        mkdir -p "${PROJECT_ROOT}/zig-out/bin"
        cp "$local_src" "${PROJECT_ROOT}/zig-out/bin/zag-${OS}-${ARCH}${SUFFIX}"
        chmod +x "${PROJECT_ROOT}/zig-out/bin/zag-${OS}-${ARCH}${SUFFIX}"
        success "Placed zig-out/bin/zag-${OS}-${ARCH}${SUFFIX}"
    else
        error "Built binary not found at ${local_src}"
        echo ""
        echo "  Set ZAG_BUILD_OUT to the directory containing the zag binary:"
        echo "    ZAG_BUILD_OUT=build ./run_all.sh --build"
        exit 1
    fi
fi

# ── Locate the built zag binary ───────────────────────────────────────────────

find_zag_binary() {
    # 1. Explicit ZAG_BIN override
    if [ -n "${ZAG_BIN:-}" ]; then
        if [ -x "$ZAG_BIN" ]; then
            echo "$ZAG_BIN"
            return 0
        fi
        # Override was set but not executable — warn, then fall through
        echo -e "  ${YELLOW}⚠${NC} ZAG_BIN='${ZAG_BIN}' is not executable — auto-detecting instead" >&2
    fi

    # 2. Auto-detect from zig-out/bin/ (built binary for this platform)
    read -r OS ARCH SUFFIX <<< "$(detect_platform)"
    local packaged="${PROJECT_ROOT}/zig-out/bin/zag-${OS}-${ARCH}${SUFFIX}"
    if [ -x "$packaged" ]; then
        echo "$packaged"
        return 0
    fi

    # 3. Check target/release/ (Rust-style cargo build output)
    local cargo_bin="${PROJECT_ROOT}/target/release/zag${SUFFIX}"
    if [ -x "$cargo_bin" ]; then
        echo "$cargo_bin"
        return 0
    fi

    # 4. Check if zag is on PATH
    local which_zag
    which_zag=$(which zag 2>/dev/null || true)
    if [ -n "$which_zag" ] && [ -x "$which_zag" ]; then
        echo "$which_zag"
        return 0
    fi

    return 1
}

if ! ZAG_BIN=$(find_zag_binary); then
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  zag binary not found.                                      ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║  Build the compiler first, then re-run:                      ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║    ./run_all.sh --build                                      ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║  Or build manually:                                          ║${NC}"
    echo -e "${RED}║    cd <repo-root> && zig build                               ║${NC}"
    echo -e "${RED}║    ./scripts/package.sh dev                                  ║${NC}"
    echo -e "${RED}║                                                              ║${NC}"
    echo -e "${RED}║  Or set ZAG_BIN to the path of the zag compiler binary.      ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    exit 1
fi

# ── Discover examples ────────────────────────────────────────────────────────

cd "$SCRIPT_DIR"

if [[ -n "$FILTER" ]]; then
    # Normalize: ensure trailing /
    [[ "$FILTER" != */ ]] && FILTER="${FILTER}/"
    EXAMPLES_DIR="${SCRIPT_DIR}/${FILTER}"
    if [[ ! -d "$EXAMPLES_DIR" ]]; then
        echo -e "${RED}Error: directory '$FILTER' not found${NC}"
        exit 1
    fi
else
    EXAMPLES_DIR="$SCRIPT_DIR"
fi

mapfile -t FILES < <(find "$EXAMPLES_DIR" -name '*.zag' -type f | sort)

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo -e "${RED}No .zag files found under $EXAMPLES_DIR${NC}"
    exit 1
fi

# ── State ────────────────────────────────────────────────────────────────────

PASS=0
FAIL=0

# Per-category integer counters (passed and failed)
declare -A CAT_PASS
declare -A CAT_FAIL

# Per-category list of failing file basenames (for reporting)
declare -A CAT_FAIL_FILES

category_of() {
    local file="$1"
    local rel="${file#$SCRIPT_DIR/}"
    dirname "$rel"
}

record_pass() {
    local cat="$1"
    ((PASS++)) || true
    CAT_PASS["$cat"]=$((${CAT_PASS["$cat"]:-0} + 1))
}

record_fail() {
    local cat="$1"
    local name="$2"
    ((FAIL++)) || true
    CAT_FAIL["$cat"]=$((${CAT_FAIL["$cat"]:-0} + 1))
    if [[ -n "${CAT_FAIL_FILES["$cat"]:-}" ]]; then
        CAT_FAIL_FILES["$cat"]="${CAT_FAIL_FILES["$cat"]} ${name}"
    else
        CAT_FAIL_FILES["$cat"]="$name"
    fi
}

# ── Run all examples ─────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}═══ Zag Examples Test Harness ═══${NC}"
echo -e "Binary:   ${BOLD}${ZAG_BIN}${NC}"
echo -e "Mode:     ${BOLD}${MODE}${NC}"
echo -e "Examples: ${BOLD}${#FILES[@]}${NC} files found"
echo ""

for file in "${FILES[@]}"; do
    local_dir="$(category_of "$file")"
    local_name="$(basename "$file")"
    label="${local_dir}/${local_name}"

    printf "  %-50s " "$label"

    case "$MODE" in
        check)
            if output=$("$ZAG_BIN" check "$file" 2>&1); then
                echo -e "${GREEN}PASS${NC}"
                record_pass "$local_dir"
            else
                echo -e "${RED}FAIL${NC}"
                record_fail "$local_dir" "$local_name"
                if [[ $VERBOSE -eq 1 ]]; then
                    echo "         ┌─ stderr ─────────────────────────────"
                    echo "$output" | sed 's/^/         │ /'
                    echo "         └──────────────────────────────────────"
                fi
            fi
            ;;
        run)
            if output=$("$ZAG_BIN" run "$file" 2>&1); then
                echo -e "${GREEN}PASS${NC}"
                record_pass "$local_dir"
                if [[ $VERBOSE -eq 1 ]]; then
                    echo "$output" | sed 's/^/         │ /'
                fi
            else
                echo -e "${RED}FAIL${NC}"
                record_fail "$local_dir" "$local_name"
                if [[ $VERBOSE -eq 1 ]]; then
                    echo "         ┌─ stderr ─────────────────────────────"
                    echo "$output" | sed 's/^/         │ /'
                    echo "         └──────────────────────────────────────"
                fi
            fi
            ;;
    esac
done

# ── Summary by category ──────────────────────────────────────────────────────

TOTAL=$((PASS + FAIL))
echo ""
echo -e "${BOLD}${CYAN}─── Results by category ───${NC}"
echo ""

# Collect all categories from both pass and fail maps
for category in $(printf '%s\n' "${!CAT_PASS[@]}" "${!CAT_FAIL[@]}" | sort -u); do
    passed="${CAT_PASS[$category]:-0}"
    failed="${CAT_FAIL[$category]:-0}"

    if [[ $failed -eq 0 ]]; then
        status="${GREEN}✓${NC}"
    else
        status="${RED}✗${NC}"
    fi

    printf "  %s  %-25s  %s%3d passed%s  %s%3d failed%s\n" \
        "$status" "$category" \
        "$GREEN" "$passed" "$NC" \
        "$RED" "$failed" "$NC"
done

# ── Final verdict ────────────────────────────────────────────────────────────

echo ""
if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${BOLD}${GREEN}All ${TOTAL} examples passed.${NC}"
else
    echo -e "  ${BOLD}${RED}${FAIL}/${TOTAL} examples failed.${NC}"
    echo ""

    # List individual failing files per category
    for category in $(printf '%s\n' "${!CAT_FAIL_FILES[@]}" | sort); do
        files="${CAT_FAIL_FILES[$category]}"
        for f in $files; do
            printf "    ${RED}✗${NC}  ${category}/${f}\n"
        done
    done

    if [[ "$VERBOSE" -eq 0 && $FAIL -gt 0 ]]; then
        echo -e "  Re-run with ${BOLD}--verbose${NC} to see compiler output."
        echo ""
    fi
fi
echo ""

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
