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

# Minimum Zig version that the compiled `zag` runtime requires to drive
# native codegen. Lower via ZAG_MIN_ZIG_{MAJOR,MINOR,PATCH} env vars only for
# forward-compatibility testing.
ZAG_MIN_ZIG_MAJOR="${ZAG_MIN_ZIG_MAJOR:-0}"
ZAG_MIN_ZIG_MINOR="${ZAG_MIN_ZIG_MINOR:-16}"
# Normalize ZAG_MIN_ZIG_PATCH via printf '%d'. Strips leading zeros
# ("007" -> "7") and rejects non-integer input ("0.0", "1a"); the
# diagnostic on stderr is silenced (2>/dev/null) and the || fallback
# sets the value to 0 so the download URL never carries a malformed
# version segment. PowerShell mirrors via [int]::TryParse, which
# parses to the same integer.
ZAG_MIN_ZIG_PATCH=$(printf '%d' "${ZAG_MIN_ZIG_PATCH:-0}" 2>/dev/null) || ZAG_MIN_ZIG_PATCH=0
ZAG_MIN_ZIG_VERSION="${ZAG_MIN_ZIG_MAJOR}.${ZAG_MIN_ZIG_MINOR}"
# Full version triplet used in the ziglang.org download URL. ziglang.org
# publishes archives under MAJOR.MINOR.PATCH, not MAJOR.MINOR.
ZAG_MIN_ZIG_FULL="${ZAG_MIN_ZIG_VERSION}.${ZAG_MIN_ZIG_PATCH}"

# Optional escape hatches (both wired in this commit):
#   ZAG_FORCE_REDOWNLOAD_ZIG=1  clear $ZAG_HOME/zig/ before re-resolving (find_zig)
#   ZAG_SKIP_ZIG_DOWNLOAD=1     never fetch zig; surface the loud failure (print_zig_status)
# install_zig consumes ZAG_FORCE_REDOWNLOAD_ZIG on success (sets it to 0) so the
# post-install find_zig re-resolve does not re-clear the freshly extracted cache.

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

# ── Zig toolchain detection + bundled download ─────────────────────────────
#
# 3-step detection tree:
#   1. $ZAG_HOME/zig/zig cache  (Zag-bundled; reproducible build).
#   2. `zig` on $PATH           (user-managed toolchain).
#   3. Fall-through             fetch the official Zig archive into
#                                $ZAG_HOME/zig/, then re-resolve.
#
# Cache invalidation: ZAG_FORCE_REDOWNLOAD_ZIG=1 clears $ZAG_HOME/zig/ before
# re-resolving, so the Zig floor can be upgraded by re-running with that flag.
# ZAG_SKIP_ZIG_DOWNLOAD=1 disables the bundled download entirely.
#
# bash-only — the PowerShell mirror lives in install.ps1.

# Strip a Zig prerelease / dev suffix so MAJOR.MINOR floor comparisons don't
# trip on dev tags. ("0.16.0-dev.1234+abc" -> "0.16.0".)
zig_strip_prerelease() {
    echo "$1" | sed -E 's/[-+].*$//'
}

# Returns 0 (true) when $1 (MAJOR.MINOR[.PATCH]) >= $2 (MAJOR.MINOR floor).
# Pre-release / dev suffixes on $1 are stripped before the comparison so a
# dev build of the same minor isn't accidentally bumped above the floor.
version_gte() {
    local actual floor
    actual=$(zig_strip_prerelease "$1")
    floor="$2"
    [ "$(printf '%s\n%s\n' "$actual" "$floor" | sort -V | head -n1)" = "$floor" ]
}

# Extract the first MAJOR.MINOR[.PATCH] string from a zig binary's `version`
# output. Tolerant of multi-line greetings ("Welcome to zig\n0.16.0-dev...")
# and labelled-prefix outputs ("zig 0.16.0") because the regex is unanchored:
# grep -o returns the leftmost semver-shaped triplet regardless of where it
# appears in the string. The trailing `|| true` suppresses the pipefail-
# driven non-zero exit on empty match, so the function always returns 0 and
# callers can capture an empty string cleanly under set -euo pipefail.
extract_zig_ver() {
    "$1" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true
}

# Resolve an acceptable `zig` binary using the 3-step detection tree:
#   1. $ZAG_HOME/zig/zig cache  (Zag-bundled; reproducible build).
#   2. `zig` on $PATH           (user-managed toolchain).
#   3. Fall-through             RESOLVED_ZIG_PATH left empty; caller decides.
# On success, sets RESOLVED_ZIG_PATH and prints a one-line status.
find_zig() {
    # Optional: force-clear ZAG_HOME cache before re-resolving. Wired now so
    # the env var is live; install_zig reuses this same cache slot.
    if [ "${ZAG_FORCE_REDOWNLOAD_ZIG:-0}" = "1" ] && [ -d "$ZAG_HOME/zig" ]; then
        info "Clearing cached Zig at $ZAG_HOME/zig (ZAG_FORCE_REDOWNLOAD_ZIG=1)"
        rm -rf "$ZAG_HOME/zig"
    fi

    RESOLVED_ZIG_PATH=""
    RESOLVED_ZIG_VER=""
    local cached="$ZAG_HOME/zig/zig"

    # 1) ZAG_HOME cache wins. Empty-string cache_ver (from extract_zig_ver)
    # flows naturally into version_gte, which returns false for empty inputs,
    # so cache rejection is silent.
    if [ -x "$cached" ]; then
        local cache_ver=""
        cache_ver=$(extract_zig_ver "$cached")
        if version_gte "$cache_ver" "$ZAG_MIN_ZIG_VERSION"; then
            RESOLVED_ZIG_PATH="$cached"
            RESOLVED_ZIG_VER="$cache_ver"
            return 0
        fi
    fi

    # 2) $PATH fallback.
    if command -v zig >/dev/null 2>&1; then
        local path_zig="" path_ver=""
        path_zig=$(command -v zig)
        path_ver=$(extract_zig_ver "$path_zig")
        if version_gte "$path_ver" "$ZAG_MIN_ZIG_VERSION"; then
            RESOLVED_ZIG_PATH="$path_zig"
            RESOLVED_ZIG_VER="$path_ver"
            return 0
        fi
    fi

    # 3) Fall-through. Caller (print_zig_status) decides whether to fetch.
    return 1
}

# Download and extract the minimum-version Zig toolchain into $ZAG_HOME/zig/.
# Mirrors the zag-install path: helper downloader, mktemp scratch dir, archive
# extraction, post-extract verification. On success, $ZAG_HOME/zig/zig (or
# zig.exe on git-bash Windows) is executable. Returns 0 on success, 1 on
# failure; surfaces its own error messaging so the caller can just propagate
# the exit code.
install_zig() {
    local host_os host_arch ext archive_name url tmp_dir archive_path inner_dir zig_cache
    case "$PLATFORM_OS" in
        linux)   host_os="linux" ;;
        darwin)  host_os="macos" ;;
        windows) host_os="windows" ;;
        *)
            warn "Cannot determine Zig host OS for ${PLATFORM_OS}."
            warn "Install Zig manually from https://ziglang.org/download/ or set ZAG_SKIP_ZIG_DOWNLOAD=1."
            return 1
            ;;
    esac
    case "$PLATFORM_ARCH" in
        x86_64) host_arch="x86_64" ;;
        arm64)  host_arch="aarch64" ;;
        *)
            warn "Cannot determine Zig host arch for ${PLATFORM_ARCH}."
            warn "Install Zig manually from https://ziglang.org/download/ or set ZAG_SKIP_ZIG_DOWNLOAD=1."
            return 1
            ;;
    esac
    [ "$host_os" = "windows" ] && ext="zip" || ext="tar.xz"
    archive_name="zig-${host_os}-${host_arch}-${ZAG_MIN_ZIG_FULL}.${ext}"
    url="https://ziglang.org/download/${ZAG_MIN_ZIG_FULL}/${archive_name}"

    tmp_dir=$(mktemp -d)
    archive_path="${tmp_dir}/${archive_name}"
    zig_cache="$ZAG_HOME/zig"

    info "Downloading ${archive_name}..."
    info "  ${url}"
    if ! download "$url" "$archive_path"; then
        rm -rf "$tmp_dir"
        warn "Failed to download Zig ${ZAG_MIN_ZIG_FULL}."
        warn "Install manually from https://ziglang.org/download/ or set ZAG_SKIP_ZIG_DOWNLOAD=1."
        return 1
    fi

    info "Extracting..."
    if [ "$ext" = "zip" ]; then
        if ! unzip -qo "$archive_path" -d "$tmp_dir"; then
            rm -rf "$tmp_dir"
            warn "Failed to extract Zig archive (unzip failed)."
            warn "Install manually from https://ziglang.org/download/ or set ZAG_SKIP_ZIG_DOWNLOAD=1."
            return 1
        fi
    else
        if ! tar -xJf "$archive_path" -C "$tmp_dir"; then
            rm -rf "$tmp_dir"
            warn "Failed to extract Zig archive (tar -xJf failed; xz-utils may be missing)."
            warn "Install xz-utils, install Zig manually, or set ZAG_SKIP_ZIG_DOWNLOAD=1."
            return 1
        fi
    fi

    # Zig archives always extract into a single versioned subdir like
    # zig-linux-x86_64-0.16.0/. Flatten that one level so detection paths
    # like $ZAG_HOME/zig/zig land on the binary directly.
    inner_dir=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -n1)
    if [ -z "$inner_dir" ]; then
        rm -rf "$tmp_dir"
        warn "Zig archive did not contain a zig-*/ directory."
        warn "Install manually from https://ziglang.org/download/ or set ZAG_SKIP_ZIG_DOWNLOAD=1."
        return 1
    fi

    # Replace the cache slot in one shot to avoid interleaving with any
    # stale files from a corrupt previous install.
    rm -rf "$zig_cache"
    mkdir -p "$zig_cache"
    cp -a "$inner_dir"/. "$zig_cache"/
    rm -rf "$tmp_dir"

    # Restore the executable bit: cross-build quirks occasionally lose it.
    chmod +x "$zig_cache/zig" 2>/dev/null || true

    # Verify the binary is present + executable. zig.exe is checked because
    # git-bash on Windows installs the .exe form.
    if [ ! -x "$zig_cache/zig" ] && [ ! -x "$zig_cache/zig.exe" ]; then
        warn "Extracted Zig archive did not contain a zig binary."
        warn "Install manually from https://ziglang.org/download/ or set ZAG_SKIP_ZIG_DOWNLOAD=1."
        return 1
    fi

    success "Zig ${ZAG_MIN_ZIG_FULL} downloaded to $zig_cache"
    # Consume ZAG_FORCE_REDOWNLOAD_ZIG so the post-install find_zig re-resolve
    # below doesn't re-clear the freshly extracted cache.
    ZAG_FORCE_REDOWNLOAD_ZIG=0
    return 0
}

# Walk up from $PWD looking for the closest enclosing zag source
# clone (a directory containing both build.zig and src/main.zig --
# the two source files that uniquely identify a zag checkout, so a
# stray build.zig from another project doesn't false-positive).
# Echoes the clone-root absolute path on stdout; returns 1 if no
# enclosing clone is found. Pure bash, no regex, no shell-substitution
# pitfalls.
find_zag_clone_root() {
    local d="${PWD}"
    while [ "$d" != "/" ]; do
        if [ -f "$d/build.zig" ] && [ -f "$d/src/main.zig" ]; then
            echo "$d"
            return 0
        fi
        local next
        next=$(dirname "$d")
        # On a relative PWD that resolves to "." (e.g., a subshell'd
        # `cd subdir && ./install.sh` from the parent's cwd), dirname
        # returns "." and we would loop forever. Break on no progress.
        [ "$next" = "$d" ] && return 1
        d="$next"
    done
    return 1
}

# Mirror the fresh zig install at $ZAG_HOME/zig into vendor/zig/ of
# the enclosing zag source clone (if any). The mirror is a *full
# directory tree copy*, not just the binary, because zig at runtime
# resolves its install directory by walking up from the binary's
# argv[0] path and looking for sibling `lib/` + std artifacts --
# without those siblings, a recursive `zig build install
# -Dzig_payload=vendor/zig/zig` from the smoke runner fails with
# "unable to find zig installation directory". Best-effort: errors
# stay silent so non-clone installs -- the typical `curl | bash`
# case -- remain no-ops. When the clone IS detected and the mirror
# succeeds, print a one-line hint about rebuilding zag with the
# vendored zig as the embedded payload -- that is the "production
# fetch path".
mirror_zig_into_vendor() {
    local zig_cache="$ZAG_HOME/zig"
    [ ! -d "$zig_cache" ] && return 0

    local clone_root
    clone_root=$(find_zag_clone_root) || return 0

    # Atomic mirror: copy into a sibling temp dir first, then swap
    # into place via `mv`. POSIX `rename(2)` (what `mv` calls when
    # both sides are dirs on the same filesystem) atomically replaces
    # whatever is at the destination, so we deliberately do NOT
    # pre-`rm` `$vendor_zig_dir` -- if we did and `mv` then failed
    # (cross-device-link edge case, perm error, signal), we'd lose
    # the prior good install AND fail to place the new one.
    # cp-to-tmp + mv-on-success preserves the previous install until
    # the new tree is fully populated; a failed cp rolls back cleanly
    # via tmp cleanup.
    #
    # Cross-platform note: the bash side relies on POSIX rename(2)
    # atomic-replace (true on every Unix since 4.2 BSD). The PS-side
    # mirror in `install.ps1` -- where PS 5.1's `Move-Item` moves
    # INTO rather than atomic-replaces an existing destination
    # directory -- DOES need an explicit pre-`Remove-Item` before the
    # swap. Do NOT "harmonize" the two patterns: each side trusts
    # its own platform's atomic-replace-or-pre-cleanup contract, and
    # a future reader fixing one side could otherwise reintroduce a
    # silent regression in the other.
    local vendor_zig_dir="$clone_root/vendor/zig"
    local tmp_mirror
    tmp_mirror=$(mktemp -d "${vendor_zig_dir}.tmp.XXXXXX" 2>/dev/null) || return 0
    if ! cp -a "$zig_cache"/. "$tmp_mirror"/ 2>/dev/null; then
        rm -rf "$tmp_mirror" 2>/dev/null
        return 0
    fi
    if ! mv "$tmp_mirror" "$vendor_zig_dir" 2>/dev/null; then
        rm -rf "$tmp_mirror" 2>/dev/null
        return 0
    fi
    # Restore the executable bit on the binary; cross-platform
    # extraction quirks occasionally lose it.
    if [ -e "$vendor_zig_dir/zig" ]; then
        chmod +x "$vendor_zig_dir/zig" 2>/dev/null || true
    elif [ -e "$vendor_zig_dir/zig.exe" ]; then
        chmod +x "$vendor_zig_dir/zig.exe" 2>/dev/null || true
    fi
    success "Vendored zig install tree at $vendor_zig_dir"
    info "  To rebuild zag with this bundled zig embedded:"
    info "    zig build install -Dzig_payload=$vendor_zig_dir/zig"
    return 0
}

# Pretty-print zig-toolchain readiness using find_zig + install_zig.
# find_zig owns the resolution logic; print_zig_status owns the user-facing
# lines so we never double-print the same fact. On fall-through, install_zig
# is invoked once; if it fails, the failure message is the finally-shown
# status. ZAG_SKIP_ZIG_DOWNLOAD=1 still short-circuits before any network I/O.
#
# Respects two escape hatches: ZAG_FORCE_REDOWNLOAD_ZIG=1 (consumed inside
# find_zig's cache-clear block and again inside install_zig's success path)
# and ZAG_SKIP_ZIG_DOWNLOAD=1 (literal -eq check, not just truthiness, so
# "0" / "" remain disabled by default).
print_zig_status() {
    if find_zig; then
        success "Zig ${RESOLVED_ZIG_VER} at ${RESOLVED_ZIG_PATH}"
        # Mirror the resolved zig binary into vendor/zig/zig of the
        # enclosing zag source clone (if any). Best-effort: a non-clone
        # install is the typical curl-pipe case and stays a no-op.
        mirror_zig_into_vendor
        return 0
    fi
    if [ "${ZAG_SKIP_ZIG_DOWNLOAD:-0}" = "1" ]; then
        warn "Zig ${ZAG_MIN_ZIG_VERSION}+ not detected and ZAG_SKIP_ZIG_DOWNLOAD=1."
        warn "  Bring your own Zig onto \$PATH before running any zag commands."
        return 1
    fi
    info "Zig ${ZAG_MIN_ZIG_VERSION}+ not detected. Downloading bundled toolchain..."
    if ! install_zig; then
        # install_zig already surfaced the failure message.
        return 1
    fi
    # Re-resolve: the cache slot should now contain a valid zig.
    if find_zig; then
        success "Zig ${RESOLVED_ZIG_VER} at ${RESOLVED_ZIG_PATH}"
        # Mirror the freshly-downloaded zig into vendor/zig/zig of the
        # enclosing zag source clone (if any).
        mirror_zig_into_vendor
        return 0
    fi
    error "Zig was downloaded but find_zig still cannot resolve it. Check $ZAG_HOME/zig."
    return 1
}

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
    if do_check; then
        echo ""
        # zag installed; surface zig status without affecting the do_check exit.
        print_zig_status || true
        exit 0
    fi
    exit 1
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
    # Even when zag is already installed, surface zig status so the user
    # knows whether .zag builds will work out of the box.
    print_zig_status || true
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

# Surface zig toolchain readiness now that zag itself is installed.
# Warn-only (non-fatal): an offline user installing zag can fetch zig later,
# so blocking the install on a network check would feel brittle. When the
# bundled download ships, this same call will resolve the fall-through into
# a download instead of the warning below.
echo ""
print_zig_status || true

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
