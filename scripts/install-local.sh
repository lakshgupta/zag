#!/usr/bin/env bash
# install-local.sh — install the locally-built zag binary from dist/bins/
#
# Usage:
#   ./scripts/install-local.sh             # install the local binary
#   ./scripts/install-local.sh --check      # verify installation
#   ./scripts/install-local.sh --uninstall  # remove installation
#   ./scripts/install-local.sh --force      # reinstall even if up to date
#
# Environment variables:
#   ZAG_HOME     Installation root (default: ~/.zag)
#   ZAG_BINS_DIR Directory containing built binaries (default: auto-detected)

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

ZAG_HOME="${ZAG_HOME:-$HOME/.zag}"
ZAG_BIN_DIR="$ZAG_HOME/bin"
ZAG_BIN="$ZAG_BIN_DIR/zag"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZAG_BINS_DIR="${ZAG_BINS_DIR:-$REPO_ROOT/zig-out/bin}"

CHECK_ONLY=0
UNINSTALL=0
FORCE=0

# ── Helpers ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}→${NC} $*"; }
success() { echo -e " ${GREEN}✓${NC} $*"; }
warn()    { echo -e " ${YELLOW}⚠${NC} $*"; }
error()   { echo -e " ${RED}✗${NC} $*" >&2; }

usage() {
    cat <<HELP
Usage: install-local.sh [flags]

Install the locally-built zag binary from dist/bins/ into ~/.zag/bin/
and configure your shell PATH.

Flags:
  --check      Verify that zag is installed and working
  --uninstall  Remove zag from ~/.zag/ and clean up PATH
  --force      Force reinstall even if already up to date
  --help       Show this help message

Environment:
  ZAG_HOME     Installation root (default: ~/.zag)
  ZAG_BINS_DIR Directory containing built binaries (default: repo-root/dist/bins)
HELP
    exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)     CHECK_ONLY=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --force)     FORCE=1 ;;
        --help)      usage ;;
        *)           ;;
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
LOCAL_BIN="$ZAG_BINS_DIR/zag-${OS}-${ARCH}${SUFFIX}"

# ── Check installation ───────────────────────────────────────────────────────

do_check() {
    echo ""
    echo -e "${BOLD}Zag local installation check${NC}"
    echo ""

    if [[ -x "$ZAG_BIN" ]]; then
        success "Binary found: $ZAG_BIN"
        if "$ZAG_BIN" version 2>/dev/null; then
            success "Runs successfully"
            if [[ -d "$ZAG_HOME/lib/std" ]]; then
                local stdlib_count
                stdlib_count=$(find "$ZAG_HOME/lib/std" -maxdepth 1 -name '*.zag' 2>/dev/null | wc -l)
                success "Stdlib present at $ZAG_HOME/lib/std/ ($stdlib_count modules)"
            else
                warn "Stdlib missing at $ZAG_HOME/lib/std/"
                warn "  `zag build` will fail in end-user projects (src/main.zig 3-tier search)"
            fi
            return 0
        else
            warn "Binary exists but fails to run"
            return 1
        fi
    else
        error "Not installed — no binary at $ZAG_BIN"
        echo ""
        echo "  Run: ./scripts/install-local.sh"
        return 1
    fi
}

if [[ $CHECK_ONLY -eq 1 ]]; then
    do_check
    exit $?
fi

# ── Uninstall ────────────────────────────────────────────────────────────────

do_uninstall() {
    echo ""
    echo -e "${BOLD}Uninstalling local zag installation${NC}"
    echo ""

    if [[ -d "$ZAG_HOME" ]]; then
        info "Removing $ZAG_HOME"
        rm -rf "$ZAG_HOME"
        success "Removed $ZAG_HOME"
    else
        warn "Nothing to uninstall — $ZAG_HOME not found"
    fi

    # Clean PATH from shell config files
    local cleaned=0
    for profile in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.config/fish/config.fish"; do
        if [[ -f "$profile" ]]; then
            if grep -q "$ZAG_BIN_DIR" "$profile" 2>/dev/null; then
                info "Removing PATH entry from ${profile/#$HOME\//~/}"
                sed -i "/# zag/,+1d" "$profile" 2>/dev/null || true
                sed -i "/export PATH=.*$ZAG_BIN_DIR/d" "$profile" 2>/dev/null || true
                cleaned=1
            fi
        fi
    done

    if [[ $cleaned -eq 0 ]]; then
        info "No PATH entries to clean"
    fi

    echo ""
    success "Uninstall complete. Restart your shell or run: source ~/.bashrc"
}

if [[ $UNINSTALL -eq 1 ]]; then
    do_uninstall
    exit 0
fi

# ── Detect shell profile ─────────────────────────────────────────────────────

detect_shell_profile() {
    local shell_name
    shell_name="$(basename "${SHELL:-bash}")"

    case "$shell_name" in
        zsh)  echo "$HOME/.zshrc" ;;
        bash) echo "$HOME/.bashrc" ;;
        fish) echo "$HOME/.config/fish/config.fish" ;;
        *)    echo "$HOME/.profile" ;;
    esac
}

# ── Install ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}═══ Zag Local Install ═══${NC}"
echo ""
echo -e "  OS/Arch:   ${OS}-${ARCH}"
echo -e "  From:      ${LOCAL_BIN}"
echo -e "  To:        ${ZAG_BIN}"
echo ""

# Check source binary exists
if [[ ! -f "$LOCAL_BIN" ]]; then
    error "No local binary found at $LOCAL_BIN"
    echo ""
    echo "  Build the compiler first, then try again:"
    echo ""
    echo "    cd $REPO_ROOT"
    echo "    zig build"
    echo ""
    echo "  Or specify a custom bins directory:"
    echo ""
    echo "    ZAG_BINS_DIR=./zig-out/bin ./scripts/install-local.sh"
    echo ""
    exit 1
fi

# Check if already installed and up to date

# v0.1 stdlib migration: refresh $ZAG_HOME/lib/std/ BEFORE
# the binary-freshness check so a no-op re-install (binary
# bytes unchanged) still picks up changed/added lib/std/*.zag
# files. Without this, users adding a new stdlib module
# re-running this script WITHOUT --force would carry a stale
# `~/.zag/lib/std/` and hit the v0.1 migration FileNotFound
# bug at the next `zag build` in their project.

# v0.1 stdlib migration: copy lib/std/*.zag next to the binary
# so `zag build` in end-user projects (where cwd has no
# `lib/std/`) can locate the stdlib at runtime. src/main.zig's
# `materializeStdlib()` 3-tier search tries cwd-relative first
# (preserves in-tree dev workflow), then `$ZAG_HOME/lib/std/`
# (this installation), then `$HOME/.local/share/zag/lib/std/`
# (future distro package path). Without this copy, the cwd-tier
# fails for projects outside the zag source tree, leading to
# empty `build/gen/std/*.zig` and `@import("std/<n>.zig")`
# FileNotFound errors when zig compiles the user's main.zig.
# (See v0.1 migration commit `fix(codegen): ...` for the
# matching search-path fallback in src/main.zig.)
ZAG_LIB_DIR="$ZAG_HOME/lib"
ZAG_STDLIB_DIR="$ZAG_LIB_DIR/std"
if [[ -d "$REPO_ROOT/lib/std" ]]; then
    info "Copying stdlib to $ZAG_STDLIB_DIR/"
    mkdir -p "$ZAG_STDLIB_DIR"
    # `cp -r` with explicit `.` preserves the dir's contents
    # (avoiding an extra nesting level `$ZAG_STDLIB_DIR/std/...`)
    # and tolerates an already-present destination.
    cp -r "$REPO_ROOT/lib/std/." "$ZAG_STDLIB_DIR/"
    success "Installed stdlib ($REPO_ROOT/lib/std -> $ZAG_STDLIB_DIR)"
else
    warn "no $REPO_ROOT/lib/std/ found -- stdlib not installed"
    warn "  `zag build` will fail in end-user projects until you fix this"
    warn "  (re-run install-local.sh from a cloned zag repo, or set ZAG_LIB_DIR manually)"
fi


# Already-up-to-date check (BEFORE binary install). When not
# --forced AND a prior binary exists AND its bytes match the
# local build, exit early to skip the re-install. The
# v0.1 stdlib copy block above already refreshed lib/std/
# on this entry, so a "no-op-binary-install" run still picks
# up changed stdlib surface -- the user's reported symptom
# ("cmp + stdlib copy silently skipped on non-ReleaseFast
# invocations") is resolved by colocating the bump-time refresh
# (stdlib copy block) with this byte-equality early-exit.
if [[ -x "$ZAG_BIN" ]] && [[ $FORCE -eq 0 ]]; then
    if cmp -s "$LOCAL_BIN" "$ZAG_BIN"; then
        success "Already up to date at $ZAG_BIN"
        echo ""
        echo "  Use --force to reinstall anyway."
        exit 0
    else
        info "Updating existing installation"
    fi
fi

# Install
mkdir -p "$ZAG_BIN_DIR"
info "Copying binary to $ZAG_BIN_DIR/"
cp "$LOCAL_BIN" "$ZAG_BIN"
chmod +x "$ZAG_BIN"
success "Installed $ZAG_BIN"

# Verify AFTER install (not before, as the prior order
# assumed $ZAG_BIN existed already -- broken on fresh
# installs with no prior binary at ~/.zag/bin/zag, which is
# the user's actual fresh-install path).
if "$ZAG_BIN" version 2>/dev/null; then
    success "Binary verified — runs correctly"
else
    error "Binary copied but fails to run — it may need to be rebuilt"
    exit 1
fi
# ── Configure PATH ───────────────────────────────────────────────────────────

SHELL_PROFILE="$(detect_shell_profile)"
PROFILE_SHORT="${SHELL_PROFILE/#$HOME\//~/}"

if [[ -f "$SHELL_PROFILE" ]]; then
    if grep -q "$ZAG_BIN_DIR" "$SHELL_PROFILE" 2>/dev/null; then
        success "PATH already configured in $PROFILE_SHORT"
    else
        info "Adding $ZAG_BIN_DIR to PATH in $PROFILE_SHORT"
        {
            echo ""
            echo "# zag"
            echo "export PATH=\"$ZAG_BIN_DIR:\$PATH\""
        } >> "$SHELL_PROFILE"
        success "PATH configured in $PROFILE_SHORT"
    fi
elif [[ "$SHELL_PROFILE" != "$HOME/.profile" ]]; then
    # Non-fish: create the profile
    if [[ "$SHELL_PROFILE" == *fish/config.fish ]]; then
        mkdir -p "$(dirname "$SHELL_PROFILE")"
        echo "fish_add_path $ZAG_BIN_DIR" >> "$SHELL_PROFILE"
        success "PATH configured in $PROFILE_SHORT (fish)"
    else
        echo "export PATH=\"$ZAG_BIN_DIR:\$PATH\"" >> "$SHELL_PROFILE"
        success "Created $PROFILE_SHORT with PATH entry"
    fi
else
    echo "export PATH=\"$ZAG_BIN_DIR:\$PATH\"" >> "$SHELL_PROFILE"
    success "Created $PROFILE_SHORT with PATH entry"
fi

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}Zag installed successfully!${NC}"
echo ""
echo "  Binary:  $ZAG_BIN"
echo "  Profile: $PROFILE_SHORT"
echo ""
echo "  Restart your shell or run:"
echo ""
echo "    source $PROFILE_SHORT"
echo ""
echo "  Then try:"
echo ""
echo "    zag version"
echo ""
