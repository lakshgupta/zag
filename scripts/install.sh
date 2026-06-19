#!/usr/bin/env bash
##
## install.sh — Zag Language Installer
##
## One-command install:
##   curl -sS https://zag-lang.org/install.sh | bash
##
## Or with options:
##   curl -sSO https://zag-lang.org/install.sh && bash install.sh --version 0.1.0
##
## Environment variables:
##   ZAG_HOME        Install directory (default: ~/.zag)
##   ZAG_VERSION     Version to install (default: latest)

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

ZAG_HOME="${ZAG_HOME:-$HOME/.zag}"
ZAG_BIN_DIR="${ZAG_HOME}/bin"
ZAG_REPO="zag-lang/zag"
GITHUB_DOWNLOAD="https://github.com/${ZAG_REPO}/releases"
ZAG_VERSION="${ZAG_VERSION:-latest}"

FORCE=0
CHECK_ONLY=0
UNINSTALL=0
SKIP_PATH=0

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
error()   { echo -e "  ${RED}✗${NC} $*"; }
header()  { echo -e "\n${BOLD}${CYAN}═══ $* ═══${NC}\n"; }

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: install.sh [OPTIONS]

Options:
  --check         Check if zag is installed, exit 0 if yes
  --uninstall     Remove zag from the system
  --force         Reinstall even if already installed
  --skip-path     Don't modify shell profile (manage PATH manually)
  --version VER   Install a specific version (default: latest)
  --help          Show this message

Environment:
  ZAG_HOME        Install directory (default: ~/.zag)
  ZAG_VERSION     Version to install (default: latest)

EOF
    exit 0
}

# ── Parse args ───────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)      CHECK_ONLY=1 ;;
        --uninstall)  UNINSTALL=1 ;;
        --force)      FORCE=1 ;;
        --skip-path)  SKIP_PATH=1 ;;
        --version)    ZAG_VERSION="$2"; shift ;;
        --help)       usage ;;
        *)            ;;
    esac
    shift
done

# ── Platform detection ───────────────────────────────────────────────────────

detect_platform() {
    local os arch

    case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
        linux)   os="linux" ;;
        darwin)  os="darwin" ;;
        mingw*|msys*|cygwin*) os="windows" ;;
        *)
            error "Unsupported OS: $(uname -s)"
            echo ""
            echo "  Zag currently supports Linux, macOS, and Windows (Git Bash / MSYS2)."
            exit 1
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)  arch="x86_64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)
            error "Unsupported architecture: $(uname -m)"
            echo ""
            echo "  Zag currently supports x86_64 and arm64."
            exit 1
            ;;
    esac

    PLATFORM_OS="$os"
    PLATFORM_ARCH="$arch"

    if [ "$os" = "windows" ]; then
        PLATFORM_EXT="zip"
    else
        PLATFORM_EXT="tar.gz"
    fi

    PLATFORM_FILE="zag-${os}-${arch}.${PLATFORM_EXT}"
}

detect_platform

# ── Download helper ──────────────────────────────────────────────────────────

download() {
    local url="$1"
    local dest="$2"

    if command -v curl &>/dev/null; then
        curl -sSL --fail --retry 3 "$url" -o "$dest"
    elif command -v wget &>/dev/null; then
        wget -q --show-progress --tries=3 -O "$dest" "$url"
    else
        error "Neither curl nor wget found. Please install one and retry."
        exit 1
    fi
}

# ── Check ────────────────────────────────────────────────────────────────────

do_check() {
    if [ -x "${ZAG_BIN_DIR}/zag" ]; then
        local ver
        ver=$("${ZAG_BIN_DIR}/zag" version 2>/dev/null || echo "unknown")
        echo "zag ${ver} is installed at ${ZAG_BIN_DIR}/zag"
        return 0
    else
        echo "zag is not installed."
        return 1
    fi
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

    # Remove PATH entry from shell configs
    for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.config/fish/config.fish"; do
        if [ -f "$rc" ]; then
            if grep -q '# Zag Language' "$rc" 2>/dev/null; then
                info "Removing Zag PATH entry from ${rc}..."
                if [ "$(uname)" = "Darwin" ]; then
                    sed -i '' '/# Zag Language/,+1d' "$rc"
                else
                    sed -i '/# Zag Language/,+1d' "$rc"
                fi
            fi
        fi
    done

    success "Zag has been uninstalled."
    echo ""
    echo "  You may want to remove the PATH entry manually from your shell config."
    echo "  Restart your shell or run: exec \$SHELL -l"
    exit 0
}

if [ "$UNINSTALL" -eq 1 ]; then
    do_uninstall
fi

# ── Already installed? ───────────────────────────────────────────────────────

if [ "$FORCE" -eq 0 ] && do_check &>/dev/null; then
    header "Zag is already installed"
    do_check
    echo ""
    info "To reinstall, run with --force"
    info "To uninstall, run with --uninstall"
    exit 0
fi

# ── Install ──────────────────────────────────────────────────────────────────

header "Zag Installer"

info "Platform:    ${PLATFORM_OS}-${PLATFORM_ARCH}"
info "Version:     ${ZAG_VERSION}"
info "Install to:  ${ZAG_BIN_DIR}"

# Setup directories
mkdir -p "$ZAG_BIN_DIR"

# Download URL
if [ "$ZAG_VERSION" = "latest" ]; then
    DOWNLOAD_URL="${GITHUB_DOWNLOAD}/latest/download/${PLATFORM_FILE}"
else
    DOWNLOAD_URL="${GITHUB_DOWNLOAD}/download/${ZAG_VERSION}/${PLATFORM_FILE}"
fi

# Download and extract
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo ""
info "Downloading ${PLATFORM_FILE}..."
info "  ${DOWNLOAD_URL}"

if ! download "$DOWNLOAD_URL" "${TMP_DIR}/${PLATFORM_FILE}"; then
    echo ""
    error "Failed to download Zag binary."
    echo ""
    if [ "$ZAG_VERSION" = "latest" ]; then
        echo "  No release binaries are available yet."
        echo "  You can build from source: https://github.com/${ZAG_REPO}"
    else
        echo "  Version '${ZAG_VERSION}' may not exist. Check available releases:"
        echo "    https://github.com/${ZAG_REPO}/releases"
    fi
    exit 1
fi

info "Extracting..."
if [ "$PLATFORM_EXT" = "zip" ]; then
    unzip -qo "${TMP_DIR}/${PLATFORM_FILE}" -d "$ZAG_BIN_DIR"
else
    tar -xzf "${TMP_DIR}/${PLATFORM_FILE}" -C "$ZAG_BIN_DIR"
fi

chmod +x "${ZAG_BIN_DIR}/zag" 2>/dev/null || true

# Verify binary runs
if ! "${ZAG_BIN_DIR}/zag" version &>/dev/null; then
    echo ""
    error "Installed binary does not execute correctly."
    error "The binary may be corrupted or incompatible with your system."
    exit 1
fi

success "zag binary installed to ${ZAG_BIN_DIR}/zag"

# ── PATH configuration ───────────────────────────────────────────────────────

if [ "$SKIP_PATH" -eq 1 ]; then
    echo ""
    warn "PATH not modified (--skip-path)."
    echo "  Add this to your shell profile to use zag:"
    echo "    export PATH=\"\$PATH:${ZAG_BIN_DIR}\""
    exit 0
fi

# Detect shell profile
detect_shell_profile() {
    local shell_name
    shell_name=$(basename "${SHELL:-bash}" 2>/dev/null || echo "bash")

    case "$shell_name" in
        zsh)  echo "$HOME/.zshrc" ;;
        bash) echo "$HOME/.bashrc" ;;
        fish) echo "$HOME/.config/fish/config.fish" ;;
        *)    echo "$HOME/.profile" ;;
    esac
}

SHELL_PROFILE=$(detect_shell_profile)

if ! echo "$PATH" | tr ':' '\n' | grep -qF "$ZAG_BIN_DIR"; then
    info "Adding Zag to PATH in ${SHELL_PROFILE}..."

    if [ ! -f "$SHELL_PROFILE" ]; then
        touch "$SHELL_PROFILE"
    fi

    # Check if already there (idempotent)
    if ! grep -q '# Zag Language' "$SHELL_PROFILE" 2>/dev/null; then
        if [ "$(basename "${SHELL:-bash}" 2>/dev/null)" = "fish" ]; then
            echo -e "\n# Zag Language\nfish_add_path ${ZAG_BIN_DIR}" >> "$SHELL_PROFILE"
        else
            echo -e "\n# Zag Language\nexport PATH=\"\$PATH:${ZAG_BIN_DIR}\"" >> "$SHELL_PROFILE"
        fi
    fi

    echo ""
    echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║  Zag installed successfully!                              ║${NC}"
    echo -e "${BOLD}${GREEN}║                                                           ║${NC}"
    echo -e "${BOLD}${GREEN}║  Restart your shell or run:                               ║${NC}"
    echo -e "${BOLD}${GREEN}║    source ${SHELL_PROFILE}${NC}"
    echo -e "${BOLD}${GREEN}║                                                           ║${NC}"
    echo -e "${BOLD}${GREEN}║  Then try:  zag version                                   ║${NC}"
    echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
else
    echo ""
    echo -e "${BOLD}${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║  Zag installed successfully!                              ║${NC}"
    echo -e "${BOLD}${GREEN}║                                                           ║${NC}"
    echo -e "${BOLD}${GREEN}║  Zag is already in your PATH. Try:  zag version           ║${NC}"
    echo -e "${BOLD}${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
fi
