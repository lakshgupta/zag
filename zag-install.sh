#!/usr/bin/env bash
##
## zag-install.sh — Zag Programming Language Installer
##
## One-command install (curl-pipe-bash pattern). Fetch the installer
## directly from this repo on GitHub raw (defaults to the `main` branch
## — bleeding edge):
##
##   curl -fsSL https://raw.githubusercontent.com/zag-lang/zag/main/zag-install.sh | bash
##
## Downloads the prebuilt zag binary for your platform from the latest
## GitHub Release, extracts it to `$ZAG_HOME/bin/zag` (default
## `~/.zag/bin/zag`), and appends that directory to your PATH in the
## matching shell rc file. The CLI itself runs as `zag` once installed.
##
## Supported release artifacts (publish matrix in
## `.github/workflows/release.yml` matches this list — keep the two in
## lockstep):
##
##   zag-linux-x86_64.tar.gz
##   zag-linux-arm64.tar.gz
##   zag-darwin-x86_64.tar.gz
##   zag-darwin-arm64.tar.gz
##   zag-windows-x86_64.zip
##   zag-windows-arm64.zip
##
## Usage:
##   bash zag-install.sh                 # interactive, defaults
##   bash zag-install.sh --help          # show all options
##   bash zag-install.sh --version v0.1.0          # pin a release tag
##   bash zag-install.sh --dest /usr/local/bin/zag # install to system path
##   bash zag-install.sh --no-path-modify           # skip shell rc edits
##
## PowerShell / native-Windows users: this script is bash. The PowerShell
## mirror at `scripts/install.ps1` in the source repo handles native
## Windows shells; this script still works under git-bash / WSL.

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

ZAG_REPO="zag-lang/zag"
GITHUB_DOWNLOAD="https://github.com/${ZAG_REPO}/releases"

ZAG_HOME="${ZAG_HOME:-$HOME/.zag}"
ZAG_BIN_DIR="$ZAG_HOME/bin"
ZAG_VERSION="${ZAG_VERSION:-latest}"

CHECK_ONLY=0
UNINSTALL=0
FORCE=0
SKIP_PATH=0
DEST_OVERRIDE=""

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
header()  { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}\n"; }

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: zag-install.sh [OPTIONS]

Options:
  --version <tag>      Release tag to install (e.g. v0.1.0; default: latest)
  --dest <path>        Override the binary destination (default: \$ZAG_HOME/bin/zag)
  --check              Check if zag is installed; exit 0 if yes
  --uninstall          Remove zag from the system
  --force              Reinstall even if already installed
  --no-path-modify     Skip appending PATH to shell rc files
  --help               Show this message

Environment:
  ZAG_HOME             Install root (default: ~/.zag)
  ZAG_BIN_DIR          Install bin dir (default: \$ZAG_HOME/bin)
  ZAG_VERSION          Release tag (default: latest)
EOF
    exit 0
}

# ── Parse args ───────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)        ZAG_VERSION="$2"; shift ;;
        --dest)           DEST_OVERRIDE="$2"; shift ;;
        --check)          CHECK_ONLY=1 ;;
        --uninstall)      UNINSTALL=1 ;;
        --force)          FORCE=1 ;;
        --no-path-modify) SKIP_PATH=1 ;;
        --help|-h)        usage ;;
        *)                warn "Ignoring unknown argument: $1" ;;
    esac
    shift
done

# ── Platform detection ───────────────────────────────────────────────────────
# Maps uname output → release-artifact filename (matches the matrix
# produced by .github/workflows/release.yml and packaged by
# scripts/package.sh). The Windows branch handles MSYS / git-bash /
# WSL; PowerShell-only Windows sessions get a redirect to install.ps1.

detect_platform() {
    local kernel
    kernel="$(uname -s 2>/dev/null || echo "")"

    case "$kernel" in
        Linux)   OS="linux"   ;;
        Darwin)  OS="darwin"  ;;
        MINGW*|MSYS*|CYGWIN*)
            OS="windows" ;;
        "")
            # No uname — could be a stripped Windows shell that's
            # not MSYS-tagged. Tell the user to use the PowerShell
            # installer instead, which preserves the principle that
            # bash scripts should not silently misbehave on alien
            # systems.
            error "Cannot detect platform (empty \$OSTYPE)."
            echo ""
            echo "  If you're on native Windows, use the PowerShell installer:"
            echo "    irm https://raw.githubusercontent.com/zag-lang/zag/main/scripts/install.ps1 | iex"
            echo "  (the source mirror is scripts/install.ps1)."
            exit 1
            ;;
        *)
            error "Unsupported OS: $kernel"
            echo ""
            echo "  Zag currently supports Linux, macOS, and Windows (Git Bash / MSYS / WSL)."
            echo "  For native Windows PowerShell, see scripts/install.ps1."
            exit 1
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)  ARCH="x86_64" ;;
        aarch64|arm64) ARCH="arm64"  ;;
        *)
            error "Unsupported architecture: $(uname -m)"
            echo ""
            echo "  Zag currently supports x86_64 and arm64."
            exit 1
            ;;
    esac

    if [ "$OS" = "windows" ]; then
        EXT="zip"; BIN_SUFFIX=".exe"
    else
        EXT="tar.gz"; BIN_SUFFIX=""
    fi

    ARCHIVE="zag-${OS}-${ARCH}.${EXT}"
}

detect_platform
DEST_DEFAULT="${ZAG_BIN_DIR}/zag${BIN_SUFFIX}"
DEST="${DEST_OVERRIDE:-$DEST_DEFAULT}"

# ── Download helper ──────────────────────────────────────────────────────────
# Works with curl OR wget; both are present in the typical
# linux/macos/git-bash distro surface. Sniffs `--fail --show-error` on
# curl so a 404 from a non-existent release tag surfaces as a real
# error (not a 0-byte file).

download() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --connect-timeout 30 "$@"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --tries=3 --connect-timeout=30 -O - "$1"
    else
        error "Neither curl nor wget found. Install one and retry."
        exit 1
    fi
}

# ── Check ────────────────────────────────────────────────────────────────────

do_check() {
    local probe="${ZAG_BIN_DIR}/zag"
    [ "$OS" = "windows" ] && probe="${ZAG_BIN_DIR}/zag.exe"
    if [ -x "$probe" ]; then
        echo "zag installed at $probe"
        if "${probe}" version >/dev/null 2>&1; then
            local ver
            ver="$("${probe}" version 2>/dev/null || echo unknown)"
            echo "version: $ver"
            return 0
        fi
        echo "(binary exists but does not run)"
        return 1
    fi
    echo "zag is not installed."
    return 1
}

if [ "$CHECK_ONLY" -eq 1 ]; then
    do_check
    exit $?
fi

# ── Uninstall ────────────────────────────────────────────────────────────────

do_uninstall() {
    header "Uninstalling Zag"

    if [ -d "$ZAG_HOME" ]; then
        info "Removing ${ZAG_HOME}..."
        rm -rf "$ZAG_HOME"
        success "Zag directory removed."
    else
        warn "Zag is not installed at ${ZAG_HOME}."
    fi

    local rc cleaned=0
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        if [ -f "$rc" ] && grep -q '# Zag Language' "$rc" 2>/dev/null; then
            info "Removing PATH entry from ${rc}..."
            if [ "$(uname)" = "Darwin" ]; then
                sed -i '' '/# Zag Language/,/^$/d' "$rc"
            else
                sed -i '/# Zag Language/,/^$/d' "$rc"
            fi
            cleaned=1
        fi
    done
    # Fish uses its own rc path; clean it up too.
    if [ -f "$HOME/.config/fish/config.fish" ] && grep -q 'fish_add_path.*\.zag' "$HOME/.config/fish/config.fish" 2>/dev/null; then
        info "Removing PATH entry from fish config..."
        sed -i '/# Zag Language/,/^$/d' "$HOME/.config/fish/config.fish"
        cleaned=1
    fi

    if [ "$cleaned" -eq 0 ]; then
        info "No shell-rc PATH entries to clean."
    fi

    success "Zag uninstalled."
    echo ""
    echo "  Restart your shell, or run: exec \$SHELL -l"
    exit 0
}

if [ "$UNINSTALL" -eq 1 ]; then
    do_uninstall
fi

# ── Already installed? ───────────────────────────────────────────────────────

if [ "$FORCE" -eq 0 ] && do_check >/dev/null 2>&1; then
    header "Zag is already installed"
    do_check
    echo ""
    info "To reinstall, run with --force"
    info "To uninstall, run with --uninstall"
    exit 0
fi

# ── Install ──────────────────────────────────────────────────────────────────

header "Zag Installer"

info "Platform:      ${OS}-${ARCH}"
info "Version:       ${ZAG_VERSION}"
info "Destination:   ${DEST}"

if [ -n "${DEST_OVERRIDE:-}" ]; then
    INSTALL_DIR="$(dirname "$DEST")"
else
    INSTALL_DIR="$ZAG_BIN_DIR"
fi

mkdir -p "$INSTALL_DIR"

if [ "$ZAG_VERSION" = "latest" ]; then
    DOWNLOAD_URL="${GITHUB_DOWNLOAD}/latest/download/${ARCHIVE}"
else
    DOWNLOAD_URL="${GITHUB_DOWNLOAD}/download/${ZAG_VERSION}/${ARCHIVE}"
fi

echo ""
info "Downloading ${ARCHIVE}..."
info "  ${DOWNLOAD_URL}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if ! download "$DOWNLOAD_URL" -o "$TMP_DIR/$ARCHIVE"; then
    echo ""
    error "Failed to download Zag binary."
    echo ""
    if [ "$ZAG_VERSION" = "latest" ]; then
        echo "  No release binaries are available yet at:"
        echo "    ${GITHUB_DOWNLOAD}"
        echo "  Build from source: https://github.com/${ZAG_REPO}"
    else
        echo "  Version '${ZAG_VERSION}' may not exist. Check available releases:"
        echo "    ${GITHUB_DOWNLOAD}/tags"
    fi
    exit 1
fi

info "Extracting..."
if [ "$EXT" = "zip" ]; then
    if ! (cd "$TMP_DIR" && unzip -qo "$ARCHIVE"); then
        warn "unzip not found or failed. Falling back to PowerShell Expand-Archive..."
        if command -v powershell >/dev/null 2>&1; then
            (cd "$TMP_DIR" && powershell -NoProfile -Command "Expand-Archive -Path '$ARCHIVE' -DestinationPath '.'")
        else
            error "Cannot extract .zip (no unzip, no PowerShell). Install one of them and retry."
            exit 1
        fi
    fi
else
    tar -xzf "$TMP_DIR/$ARCHIVE" -C "$INSTALL_DIR"
    # Defensive net for non-CI archive sources: some publishers wrap
    # the binary in a versioned sub-directory
    # (`zag-linux-x86_64-0.1.0/zag`). The CI-built archives in this
    # repo place `zag` + `VERSION` at top-level so the freshly-
    # extracted `$INSTALL_DIR/zag${BIN_SUFFIX}` exists after `tar`
    # and the depth-2 promoter must NOT run -- it would otherwise
    # promote a stale nested binary from a prior install and
    # overwrite the just-downloaded fresh copy.
    # Only activate the depth-2 promoter if the fresh `tar` did
    # NOT produce `$INSTALL_DIR/zag${BIN_SUFFIX}` (i.e. we're
    # genuinely staring at a nested-archive shape). `2>/dev/null ||
    # true` swallows find's "no match" exit under `set -euo
    # pipefail`.
    if [ ! -f "$INSTALL_DIR/zag${BIN_SUFFIX}" ]; then
        inner="$(find "$INSTALL_DIR" -mindepth 2 -maxdepth 2 -name "zag${BIN_SUFFIX}" -print -quit 2>/dev/null || true)"
        if [ -n "$inner" ]; then
            mv "$inner" "$INSTALL_DIR/zag${BIN_SUFFIX}"
        fi
    fi
fi

# Handle zips uniformly: stage from the temp dir into $INSTALL_DIR.
if [ "$EXT" = "zip" ]; then
    if [ -f "$TMP_DIR/zag.exe" ]; then
        cp "$TMP_DIR/zag.exe" "$INSTALL_DIR/zag.exe"
    elif [ -f "$TMP_DIR/zag" ]; then
        cp "$TMP_DIR/zag" "$INSTALL_DIR/zag.exe"
    else
        # Walk any versioned subdir the zip created.
        inner="$(find "$TMP_DIR" -name 'zag.exe' -print -quit || true)"
        if [ -n "$inner" ]; then
            cp "$inner" "$INSTALL_DIR/zag.exe"
        else
            error "Extracted .zip did not contain zag.exe"
            exit 1
        fi
    fi
fi

if [ ! -f "$INSTALL_DIR/zag${BIN_SUFFIX}" ]; then
    error "Extracted archive did not contain a zag binary at $INSTALL_DIR/zag${BIN_SUFFIX}"
    error "Inspect $TMP_DIR before re-running."
    exit 1
fi

chmod +x "$INSTALL_DIR/zag${BIN_SUFFIX}" 2>/dev/null || true

# Verify the produced binary runs.
if ! "$INSTALL_DIR/zag${BIN_SUFFIX}" version >/dev/null 2>&1; then
    error "Installed binary at $INSTALL_DIR/zag${BIN_SUFFIX} does not execute correctly."
    error "The binary may be corrupted or incompatible with this system."
    exit 1
fi
success "zag installed at $INSTALL_DIR/zag${BIN_SUFFIX}"

# ── PATH configuration ───────────────────────────────────────────────────────

if [ "$SKIP_PATH" -eq 1 ]; then
    echo ""
    warn "PATH not modified (--no-path-modify)."
    echo "  Add this to your shell profile to use zag:"
    echo "    export PATH=\"\$PATH:${INSTALL_DIR}\""
    exit 0
fi

# Pick the rc file that matches the user's detected shell on Linux/Darwin.
# Windows git-bash already gets bashrc handled by the bash startup;
# PowerShell-on-Windows users are not in this branch at all (see
# detect_platform's Windows redirect).
detect_shell_profile() {
    local name
    name="$(basename "${SHELL:-bash}")"
    case "$name" in
        zsh)  echo "$HOME/.zshrc" ;;
        bash) echo "$HOME/.bashrc" ;;
        fish) echo "$HOME/.config/fish/config.fish" ;;
        *)    echo "$HOME/.profile" ;;
    esac
}

SHELL_PROFILE="$(detect_shell_profile)"
PROFILE_SHORT="${SHELL_PROFILE/#$HOME\//~/}"

if ! echo ":$PATH:" | grep -q ":${INSTALL_DIR}:"; then
    info "Adding ${INSTALL_DIR} to PATH in ${PROFILE_SHORT}..."

    if [ ! -f "$SHELL_PROFILE" ]; then
        touch "$SHELL_PROFILE"
    fi
    if ! grep -q '# Zag Language' "$SHELL_PROFILE" 2>/dev/null; then
        if [ "$(basename "${SHELL:-bash}")" = "fish" ]; then
            printf '\n# Zag Language\nfish_add_path %s\n' "$INSTALL_DIR" >> "$SHELL_PROFILE"
        else
            printf '\n# Zag Language\nexport PATH="$PATH:%s"\n' "$INSTALL_DIR" >> "$SHELL_PROFILE"
        fi
    fi
fi

# Banner on the way out.
echo ""
echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║  Zag installed successfully!                              ║${NC}"
echo -e "${BOLD}${GREEN}║                                                           ║${NC}"
echo -e "${BOLD}${GREEN}║  Restart your shell, or run:                              ║${NC}"
echo -e "${BOLD}${GREEN}║    source ${PROFILE_SHORT}${NC}"
echo -e "${BOLD}${GREEN}║                                                           ║${NC}"
echo -e "${BOLD}${GREEN}║  Then try:  zag version                                   ║${NC}"
echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
