#!/usr/bin/env bash
##
## package.sh — Zag Cross-Platform Distribution Packager
##
## Takes built binaries and creates platform-specific distribution
## archives suitable for GitHub Releases.
##
## Usage:
##   ./package.sh <version> [--bin-dir <path>]
##
##   ./package.sh 0.1.0
##   ./package.sh 0.1.0 --bin-dir ../zig-out/bin
##
## Expected binary names in the bin directory:
##   zag-linux-x86_64        zag-linux-arm64
##   zag-darwin-x86_64       zag-darwin-arm64
##   zag-windows-x86_64.exe  zag-windows-arm64.exe
##
## Output:
##   dist/<version>/
##     zag-<version>-linux-x86_64.tar.gz    zag-<version>-linux-arm64.tar.gz
##     zag-<version>-darwin-x86_64.tar.gz   zag-<version>-darwin-arm64.tar.gz
##     zag-<version>-windows-x86_64.zip     zag-<version>-windows-arm64.zip
##     checksums.txt
##     zag-install.sh                       # standalone installer (release asset)
##     install.ps1                          # standalone PowerShell installer
##
## Archive filenames embed the BARE version (`zag-0.2.0-linux-x86_64.tar.gz`),
## matching the VERSION file inside. Every consumer — scripts/install.sh,
## scripts/install.ps1, zag-install.sh, and .github/workflows/release.yml —
## builds this exact name from the release tag; keep them in lockstep.
##
## Each archive is self-contained: the `zag` binary, a `VERSION` file,
## and the installers (`zag-install.sh` for bash / git-bash / WSL,
## `install.ps1` for native PowerShell). Running `zag-install.sh` from
## inside the extracted archive installs the bundled binary to ~/.zag/bin
## and adds it to PATH; an explicit `--version <tag>` downloads that
## release from GitHub instead.

set -euo pipefail

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

# ── Parse args ───────────────────────────────────────────────────────────────

VERSION=""
BIN_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bin-dir)
            BIN_DIR="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 <version> [--bin-dir <path>]"
            echo ""
            echo "  version     e.g. 0.1.0"
            echo "  --bin-dir   Directory containing pre-built binaries"
            echo "              (default: zig-out/bin)"
            exit 0
            ;;
        *)
            VERSION="$1"
            shift
            ;;
    esac
done

if [ -z "$VERSION" ]; then
    error "Version required. Usage: $0 <version> [--bin-dir <path>]"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${BIN_DIR:-${SCRIPT_DIR}/../zig-out/bin}"
DIST_DIR="${SCRIPT_DIR}/../dist/${VERSION}"

# ── Clean and prepare ────────────────────────────────────────────────────────

header "Zag Distribution Packager v${VERSION}"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# ── Platform definitions ─────────────────────────────────────────────────────

# format: "os arch ext bin_suffix"
TARGETS=(
    "linux   x86_64  tar.gz  "
    "linux   arm64   tar.gz  "
    "darwin  x86_64  tar.gz  "
    "darwin  arm64   tar.gz  "
    "windows x86_64  zip     .exe"
    "windows arm64   zip     .exe"
)

# ── Package each target ──────────────────────────────────────────────────────

PACKAGED=0
FAILED=0

for target_spec in "${TARGETS[@]}"; do
    read -r OS ARCH EXT SUFFIX <<< "$target_spec"

    SRC_NAME="zag-${OS}-${ARCH}${SUFFIX}"
    SRC_PATH="${BIN_DIR}/${SRC_NAME}"
    # Versioned archive name: `zag-<version>-<os>-<arch>.<ext>` (bare
    # version, no `v` — matches the VERSION file inside). Every consumer
    # (installers, release workflow) builds this exact name; keep in
    # lockstep.
    ARCHIVE_NAME="zag-${VERSION}-${OS}-${ARCH}.${EXT}"
    ARCHIVE_PATH="${DIST_DIR}/${ARCHIVE_NAME}"

    info "Packaging ${ARCHIVE_NAME}..."

    if [ ! -f "$SRC_PATH" ]; then
        warn "Binary not found at ${SRC_PATH} — creating placeholder"
        mkdir -p "$(dirname "$SRC_PATH")"
        cat > "$SRC_PATH" <<'PLACEHOLDER'
#!/usr/bin/env bash
# Placeholder zag binary — replace with real compiled binary
echo "zag dev (placeholder binary — build from source)"
PLACEHOLDER
        chmod +x "$SRC_PATH"
    fi

    # Create a temp staging directory with just the binary
    STAGING=$(mktemp -d)
    cp "$SRC_PATH" "${STAGING}/zag${SUFFIX}"
    chmod +x "${STAGING}/zag${SUFFIX}"

    # Also include a VERSION file
    echo "$VERSION" > "${STAGING}/VERSION"

    # Ship the installers with the archive so it is self-contained: the
    # user-facing `zag-install.sh` installs the bundled binary directly
    # (see its "Release-archive form" doc) and `install.ps1` covers
    # native Windows PowerShell. The release workflow mirrors this exact
    # set — keep both in lockstep.
    cp "$SCRIPT_DIR/../zag-install.sh" "${STAGING}/zag-install.sh"
    chmod +x "${STAGING}/zag-install.sh"
    if [ -f "$SCRIPT_DIR/install.ps1" ]; then
        cp "$SCRIPT_DIR/install.ps1" "${STAGING}/install.ps1"
    fi

    case "$EXT" in
        tar.gz)
            tar -czf "$ARCHIVE_PATH" -C "$STAGING" "zag${SUFFIX}" VERSION zag-install.sh install.ps1
            ;;
        zip)
            # zip without directory structure
            (cd "$STAGING" && zip -q "$ARCHIVE_PATH" "zag${SUFFIX}" VERSION zag-install.sh install.ps1)
            ;;
    esac

    rm -rf "$STAGING"

    ARCHIVE_SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)
    success "${ARCHIVE_NAME}  (${ARCHIVE_SIZE})"
    PACKAGED=$((PACKAGED + 1))
done

# ── Checksums ────────────────────────────────────────────────────────────────

echo ""
info "Generating checksums..."

CHECKSUM_FILE="${DIST_DIR}/checksums.txt"
rm -f "$CHECKSUM_FILE"

for archive in "$DIST_DIR"/*.tar.gz "$DIST_DIR"/*.zip; do
    [ -f "$archive" ] || continue
    name=$(basename "$archive")
    if command -v sha256sum &>/dev/null; then
        sha256sum "$archive" | sed "s|${DIST_DIR}/||" >> "$CHECKSUM_FILE"
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$archive" | sed "s|${DIST_DIR}/||" >> "$CHECKSUM_FILE"
    fi
done

success "checksums written to dist/${VERSION}/checksums.txt"

# ── Standalone installers ────────────────────────────────────────────────────
# Copy the installers into dist/<version>/ next to the archives so the
# local package layout matches the CI release-asset set exactly (the
# release workflow's publish job uploads these two files as standalone
# assets). Users can grab just the script and run it against a release
# tag without extracting an archive.

echo ""
info "Copying standalone installers..."

cp "$SCRIPT_DIR/../zag-install.sh" "${DIST_DIR}/zag-install.sh"
chmod +x "${DIST_DIR}/zag-install.sh"
if [ -f "$SCRIPT_DIR/install.ps1" ]; then
    cp "$SCRIPT_DIR/install.ps1" "${DIST_DIR}/install.ps1"
fi

success "zag-install.sh + install.ps1 copied to dist/${VERSION}/"

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}═══ Packaging complete ═══${NC}"
echo ""
echo "  Version:  ${VERSION}"
echo "  Packages: ${PACKAGED}"
echo "  Output:   ${DIST_DIR}/"
echo ""
echo "  Upload these files to:"
echo "    https://github.com/lakshgupta/zag/releases/new?tag=v${VERSION}"
echo ""
echo "  Files:"
for f in "$DIST_DIR"/*.tar.gz "$DIST_DIR"/*.zip "$DIST_DIR"/*.txt; do
    [ -f "$f" ] || continue
    printf "    %-40s %s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
done
echo ""
