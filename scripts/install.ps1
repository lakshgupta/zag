##
## install.ps1 — Zag Language Installer for Windows (PowerShell)
##
## One-command install:
##   powershell -c "irm https://zag-lang.org/install.ps1 | iex"
##
## Or download and run:
##   Invoke-WebRequest -Uri https://zag-lang.org/install.ps1 -OutFile install.ps1
##   .\install.ps1
##
## Environment variables:
##   $env:ZAG_HOME        Install directory (default: $HOME\.zag)
##   $env:ZAG_VERSION     Version to install (default: latest)

param(
    [switch]$Check,
    [switch]$Uninstall,
    [switch]$Force,
    [switch]$SkipPath,
    [string]$Version = $env:ZAG_VERSION
)

$ErrorActionPreference = "Stop"

# ── Configuration ────────────────────────────────────────────────────────────

$ZagHome = if ($env:ZAG_HOME) { $env:ZAG_HOME } else { Join-Path $HOME ".zag" }
$ZagBinDir = Join-Path $ZagHome "bin"
$Repo = "zag-lang/zag"
$BaseUrl = "https://github.com/$Repo/releases"

if (-not $Version) { $Version = "latest" }

# Minimum Zig version that the compiled `zag` runtime requires for native
# codegen. Lower via $env:ZAG_MIN_ZIG_{MAJOR,MINOR,PATCH} only for forward testing.
$ZagMinZigMajor = if ($env:ZAG_MIN_ZIG_MAJOR) { [int]$env:ZAG_MIN_ZIG_MAJOR } else { 0 }
$ZagMinZigMinor = if ($env:ZAG_MIN_ZIG_MINOR) { [int]$env:ZAG_MIN_ZIG_MINOR } else { 16 }
$ZagMinZigPatch = 0
# Validate $env:ZAG_MIN_ZIG_PATCH via [int]::TryParse. Anything that doesn't
# parse to a single non-negative integer ("0.0", "1a", "-5", "") would
# corrupt the download URL into 404 territory since ziglang.org's URL
# convention is MAJOR.MINOR.PATCH. The TryParse call never throws; on a
# non-integer input it returns $false and leaves $parsed at 0.
$parsed = 0
if ($env:ZAG_MIN_ZIG_PATCH) {
    [void][int]::TryParse($env:ZAG_MIN_ZIG_PATCH, [ref]$parsed)
}
$ZagMinZigPatch = $parsed
$ZagMinZigVersion = "${ZagMinZigMajor}.${ZagMinZigMinor}"
# Full version triplet used in the ziglang.org download URL. ziglang.org
# publishes archives under MAJOR.MINOR.PATCH, not MAJOR.MINOR.
$ZagMinZigFull = "${ZagMinZigVersion}.${ZagMinZigPatch}"
$script:ResolvedZigPath = ""

# ── Platform detection ───────────────────────────────────────────────────────

$OS = "windows"
$procArch = $env:PROCESSOR_ARCHITECTURE
$Arch = switch ($procArch) {
    "AMD64"  { "x86_64" }
    "ARM64"  { "arm64" }
    default {
        Write-Host "Unsupported architecture: ${procArch}. Zag currently supports x86_64 (AMD64) and arm64." -ForegroundColor Red
        exit 1
    }
}

$Ext = "zip"
$FileName = "zag-${OS}-${Arch}.${Ext}"

if ($Version -eq "latest") {
    $DownloadUrl = "${BaseUrl}/latest/download/${FileName}"
} else {
    $DownloadUrl = "${BaseUrl}/download/${Version}/${FileName}"
}

# ── Helpers ──────────────────────────────────────────────────────────────────

function Write-Info    { param([string]$Message); Write-Host "  → ${Message}" -ForegroundColor Cyan }
function Write-Success { param([string]$Message); Write-Host "  ✓ ${Message}" -ForegroundColor Green }
function Write-Warn    { param([string]$Message); Write-Host "  ⚠ ${Message}" -ForegroundColor Yellow }
function Write-ErrorMsg { param([string]$Message); Write-Host "  ✗ ${Message}" -ForegroundColor Red }
function Write-Header  { param([string]$Message); Write-Host "`n═══ ${Message} ═══`n" -ForegroundColor Cyan }

# ── Zig toolchain detection + bundled download ───────────────────────────
#
# PowerShell mirror of install.sh's 3-step detection tree:
#   1. $ZagHome\zig\zig.exe cache  (Zag-bundled; reproducible build).
#   2. zig.exe on $PATH            (user-managed toolchain).
#   3. Fall-through                fetch the official Zig archive into
#                                   $ZagHome\zig\, then re-resolve.
#
# Cache invalidation: $env:ZAG_FORCE_REDOWNLOAD_ZIG=1 clears the cache before
# re-resolving. $env:ZAG_SKIP_ZIG_DOWNLOAD=1 disables the bundled download.

# Strip a Zig prerelease / dev suffix so [version] casting doesn't error
# ("0.16.0-dev.1234+abc" -> "0.16.0").
function Get-ZigFloorVersion {
    param([string]$Actual)
    if ($Actual -match '^(\d+\.\d+(?:\.\d+)?)') { return $Matches[1] }
    return $Actual
}

# Returns $true when $Actual (MAJOR.MINOR[.PATCH]) >= $Floor (MAJOR.MINOR).
# Get-ZigFloorVersion is the format guard; [version] auto-pads MAJOR.MINOR
# to MAJOR.MINOR.0 so the comparison is well-defined on either side.
function Test-VersionGte {
    param([string]$Actual, [string]$Floor)
    $a = [version](Get-ZigFloorVersion $Actual)
    $f = [version](Get-ZigFloorVersion $Floor)
    return ($a -ge $f)
}

# Extract the first MAJOR.MINOR[.PATCH] string from a possibly multi-line
# `zig version` output. Returns $null when no semver line matches so that
# Test-VersionGte's [version] cast (now without try/catch) fails loudly
# instead of silently marking the toolchain missing.
#
# Implementation: [regex]::Matches scans the entire input string. Without
# line anchors (`^`/`$`), no multiline flag is needed, so the regex stays
# UNANCHORED (no `^`/`$`) — that way a future zig output
# like `zig 0.16.0` (label-prefixed) still resolves cleanly: the leftmost
# semver-shaped triplet anywhere in the string — whether at line start,
# mid-line, or trailing after a label — is returned.
#
# Why the explicit [regex]::Matches over Select-String: Select-String on
# a `[string]` parameter coerces multi-line arrays back into a single
# joined string before regex matching, which is implementation-defined and
# can defeat line-anchored semantics on some PowerShell versions. Going
# through [regex]::Matches is unambiguous across PS 5.1 / 7.
function Extract-ZigVersion {
    param([string]$RawOutput)
    $regexMatches = [regex]::Matches($RawOutput, '\d+\.\d+(\.\d+)?')
    if ($regexMatches.Count -gt 0) { return $regexMatches[0].Value }
    return $null
}

# Resolve an acceptable `zig` binary using the 3-step detection tree.
# Sets $script:ResolvedZigPath and $script:ResolvedZigVer on success.
function Find-Zig {
    $script:ResolvedZigPath = ""
    $script:ResolvedZigVer = ""

    # Optional: force-clear ZAG_HOME cache before re-resolving. Wired now so
    # the env var is live; Step 1 sub-step 2 will reuse this same cache slot.
    $cacheDir = Join-Path $ZagHome "zig"
    if (($env:ZAG_FORCE_REDOWNLOAD_ZIG -eq "1") -and (Test-Path $cacheDir)) {
        Write-Info "Clearing cached Zig at $cacheDir (ZAG_FORCE_REDOWNLOAD_ZIG=1)"
        Remove-Item -Recurse -Force $cacheDir
    }

    $cached = Join-Path $ZagHome "zig\zig.exe"

    # 1) ZAG_HOME cache wins.
    if (Test-Path $cached) {
        $cachedVer = Extract-ZigVersion -RawOutput (& $cached version)
        if ($cachedVer -and (Test-VersionGte -Actual $cachedVer -Floor $ZagMinZigVersion)) {
            $script:ResolvedZigPath = $cached
            $script:ResolvedZigVer = $cachedVer
            return $true
        }
    }

    # 2) $PATH / Get-Command fallback.
    $onPath = Get-Command zig -ErrorAction SilentlyContinue
    if ($onPath) {
        $pathVer = Extract-ZigVersion -RawOutput (& zig version)
        if ($pathVer -and (Test-VersionGte -Actual $pathVer -Floor $ZagMinZigVersion)) {
            $script:ResolvedZigPath = $onPath.Source
            $script:ResolvedZigVer = $pathVer
            return $true
        }
    }

    # 3) Fall-through. The bundled download lands here in Step 1 sub-step 2.
    return $false
}

# Download and extract the minimum-version Zig toolchain into $ZagHome\zig\.
# Mirrors the zag-install path: BITS transfer with Invoke-WebRequest fallback,
# GetTempPath + GetRandomFileName scratch dir, Expand-Archive extraction,
# post-extract verification. On success, $ZagHome\zig\zig.exe is executable.
# Returns $true on success, $false on failure; surfaces its own error
# messaging so the caller can just propagate.
function Install-Zig {
    $archive = "zig-${OS}-${Arch}-${ZagMinZigFull}.zip"
    $url = "https://ziglang.org/download/${ZagMinZigFull}/${archive}"

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $tmpFile = Join-Path $tmpDir $archive

    try {
        Write-Info "Downloading ${archive}..."
        Write-Info "  ${url}"
        try {
            Start-BitsTransfer -Source $url -Destination $tmpFile -ErrorAction Stop
        } catch {
            # Fallback to Invoke-WebRequest when BITS isn't available.
            Invoke-WebRequest -Uri $url -OutFile $tmpFile -ErrorAction Stop
        }

        Write-Info "Extracting..."
        Expand-Archive -Path $tmpFile -DestinationPath $tmpDir -Force -ErrorAction Stop

        # Zig archives always extract into a single versioned subdir like
        # zig-windows-x86_64-0.16.0\. Flatten that one level so detection
        # paths like $ZagHome\zig\zig.exe land on the binary directly.
        $innerDir = Get-ChildItem -Path $tmpDir -Directory | Select-Object -First 1
        if (-not $innerDir) {
            Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
            Write-Warn "Zig archive did not contain a zig-*/ directory."
            Write-Warn "Install manually from https://ziglang.org/download/ or set ZAG_SKIP_ZIG_DOWNLOAD=1."
            return $false
        }

        # Replace the cache slot in one shot to avoid interleaving with any
        # stale files from a corrupt previous install.
        $zigCache = Join-Path $ZagHome "zig"
        if (Test-Path $zigCache) { Remove-Item -Recurse -Force $zigCache }
        New-Item -ItemType Directory -Force -Path $zigCache | Out-Null

        Get-ChildItem -Path $innerDir.FullName -Force | ForEach-Object {
            Move-Item -Path $_.FullName -Destination $zigCache -Force
        }

        $zigExe = Join-Path $zigCache "zig.exe"
        if (-not (Test-Path $zigExe)) {
            Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
            Write-Warn "Extracted Zig archive did not contain zig.exe"
            Write-Warn "Install manually from https://ziglang.org/download/ or set ZAG_SKIP_ZIG_DOWNLOAD=1."
            return $false
        }

        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        Write-Success "Zig $ZagMinZigFull downloaded to $zigCache"
        # Consume ZAG_FORCE_REDONLOAD_ZIG so the post-install Find-Zig
        # re-resolve doesn't re-clear the freshly extracted cache.
        $env:ZAG_FORCE_REDOWNLOAD_ZIG = "0"
        return $true
    } catch {
        Write-Warn "Failed to install Zig: $_"
        Write-Warn "Install manually from https://ziglang.org/download/ or set ZAG_SKIP_ZIG_DOWNLOAD=1."
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        return $false
    }
}

# Walk up from the current directory looking for the closest enclosing
# zag source clone (a directory containing both build.zig and
# src\main.zig -- the two source files that uniquely identify a zag
# checkout). Returns the clone-root path on success, $null if no
# enclosing clone is found.
function Find-ZagCloneRoot {
    $d = (Get-Location).Path
    while ($d -ne "") {
        $buildZig = Join-Path $d "build.zig"
        $mainZig  = Join-Path $d "src\main.zig"
        if ((Test-Path $buildZig) -and (Test-Path $mainZig)) { return $d }
        $parent = Split-Path $d -Parent
        if (($parent -eq $null) -or ($parent -eq $d)) { break }
        $d = $parent
    }
    return $null
}

# Mirror the fresh zig install at $ZagHome\zig\ into vendor\zig\ of the
# enclosing zag source clone (if any). The mirror is a *full directory
# tree copy*, not just the binary, because zig at runtime resolves
# its install directory by walking up from the binary's argv[0] path
# and looking for sibling `lib\` + std artifacts -- without those
# siblings, a recursive `zig build install -Dzig_payload=vendor\zig\zig`
# fails with "unable to find zig installation directory". Best-effort:
# errors stay silent so non-clone installs (the typical curl-pipe
# case) remain no-ops. When the clone IS detected and the mirror
# succeeds, prints a one-line hint about rebuilding zag with the
# vendored zig as the embedded payload -- that is the "production
# fetch path".
function Mirror-ZigIntoVendor {
    $zigCache = Join-Path $ZagHome "zig"
    if (-not (Test-Path $zigCache)) { return }

    $cloneRoot = Find-ZagCloneRoot
    if (-not $cloneRoot) { return }

    # Atomic-ish mirror: enumerate children and copy each to a
    # sibling temp dir first, then Move-Item swaps the destination.
    #
    # Why a pre-Remove-Item of $vendorDir + Move-Item (NOT a bare
    # Move-Item that would atomic-replace): on PowerShell 5.1
    # (still in use on Windows), Move-Item with -Destination
    # pointing at an existing directory moves the source INTO
    # that directory (vendorDir\tmpMirror\) rather than REPLACE_INPLACE.
    # That's the opposite of what we want. PS Core 7+ improved this
    # via NTFS MoveFileEx(MOVEFILE_REPLACE_EXISTING), but PS 5.1 is
    # not universal. The cross-version-safe pattern is:
    # Remove-Item the old destination, then Move-Item the new
    # tree into place. This is NOT theoretically atomic (the gap
    # between the rm and the move is non-atomic), but it is
    # predictable across PS 5.1 / PS 7+ / .NET / PowerShell Core
    # on Windows, which is the cross-platform behavior the bash
    # POSIX-rename(2) atomicity has by default. Trading away
    # theoretical atomicity for predictable cross-version semantics
    # is the right call for a scaffolding installer.
    #
    # Why Get-ChildItem + per-child Copy-Item -Recurse and NOT a
    # single `Copy-Item -Path "...\*" -Recurse -Destination X`:
    # on PowerShell 5.1, the latter pattern has historically
    # recursed INTO the destination directory, which can cause
    # infinite recursion / off-by-one path copy. Enumerating each
    # child and copying it independently sidesteps that footgun.
    #
    # Cross-platform note (mirror-side): the bash mirror in
    # `install.sh` deliberately OMITS this pre-Remove-Item because
    # POSIX `rename(2)` (which `mv` invokes between same-fs dirs)
    # atomic-replaces `$vendor_zig_dir`. A pre-rm there would
    # re-introduce the lose-both-on-mv-failure regression the
    # cp-to-tmp + mv pattern avoids. Do NOT homogenize the patterns:
    # bash pre-rm is wrong, PS pre-Remove-Item is correct, and the
    # asymmetry is platform-specific. (The bash side carries a
    # symmetric note pointing back here.)
    $vendorDir = Join-Path $cloneRoot "vendor\zig"
    $tmpMirror = Join-Path $cloneRoot ("vendor\zig.tmp." + [System.IO.Path]::GetRandomFileName())
    try {
        New-Item -ItemType Directory -Force -Path $tmpMirror | Out-Null
        Get-ChildItem -Path $zigCache -Force | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination $tmpMirror -Recurse -Force -ErrorAction Stop
        }
        if (Test-Path $vendorDir) {
            Remove-Item -Recurse -Force $vendorDir -ErrorAction Stop
        }
        Move-Item -Path $tmpMirror -Destination $vendorDir -ErrorAction Stop
        Write-Success "Vendored zig install tree at $vendorDir"
        Write-Info "  To rebuild zag with this bundled zig embedded:"
        Write-Info "    zig build install -Dzig_payload=$vendorDir\zig.exe"
    } catch {
        # Surface the failure when we DID detect a clone (the
        # production fetch path scenario); the user explicitly ran
        # install.ps1 inside a zag source clone, so silently
        # skipping the mirror would leave the override hint at -D
        # flag pointing at empty/stale data. The non-clone curl-pipe
        # case never reaches this catch (returns earlier).
        Remove-Item -Recurse -Force $tmpMirror -ErrorAction SilentlyContinue
        Write-Warn "Failed to mirror zig install tree into $vendorDir"
        Write-Warn "  Re-run with -Force, or copy $zigCache manually into $vendorDir"
    }
}

# Pretty-print zig-toolchain readiness using Find-Zig + Install-Zig.
# Find-Zig owns the resolution logic; Show-ZigStatus owns the user-facing
# lines so we never double-print the same fact. On fall-through, Install-Zig
# is invoked once; if it fails, the failure message is the finally-shown
# status. $env:ZAG_SKIP_ZIG_DOWNLOAD=1 still short-circuits before any
# network I/O.
#
# Respects two escape hatches: $env:ZAG_FORCE_REDOWNLOAD_ZIG=1 (consumed
# inside Find-Zig's cache-clear block and again inside Install-Zig's success
# path) and $env:ZAG_SKIP_ZIG_DOWNLOAD=1 (literal -eq check, not just
# truthiness, so "0" / "" remain disabled by default).
function Show-ZigStatus {
    if (Find-Zig) {
        Write-Success "Zig $script:ResolvedZigVer at $script:ResolvedZigPath"
        # Mirror the resolved zig binary into vendor\zig\zig of the
        # enclosing zag source clone (if any). Best-effort: a non-clone
        # install is the typical curl-pipe case and stays a no-op.
        Mirror-ZigIntoVendor
        return $true
    }
    if ($env:ZAG_SKIP_ZIG_DOWNLOAD -eq "1") {
        Write-Warn "Zig $ZagMinZigVersion+ not detected and ZAG_SKIP_ZIG_DOWNLOAD=1."
        Write-Warn "  Bring your own Zig onto `$PATH before running any zag commands."
        return $false
    }
    Write-Info "Zig $ZagMinZigVersion+ not detected. Downloading bundled toolchain..."
    if (-not (Install-Zig)) {
        # Install-Zig already surfaced the failure message.
        return $false
    }
    # Re-resolve: the cache slot should now contain a valid zig.
    if (Find-Zig) {
        Write-Success "Zig $script:ResolvedZigVer at $script:ResolvedZigPath"
        # Mirror the freshly-downloaded zig into vendor\zig\zig of the
        # enclosing zag source clone (if any).
        Mirror-ZigIntoVendor
        return $true
    }
    Write-ErrorMsg "Zig was downloaded but Find-Zig still cannot resolve it. Check $ZagHome\zig\."
    return $false
}

# ── Check ────────────────────────────────────────────────────────────────────

function Test-ZagInstalled {
    $zag = Join-Path $ZagBinDir "zag.exe"
    return (Test-Path $zag)
}

if ($Check) {
    if (Test-ZagInstalled) {
        $zag = Join-Path $ZagBinDir "zag.exe"
        Write-Host "zag is installed at $zag"
        Write-Host ""
        # Surface zig status alongside zag so --Check reports the full picture
        # without changing the script's exit semantics.
        $null = Show-ZigStatus
        exit 0
    } else {
        Write-Host "zag is not installed."
        exit 1
    }
}

# ── Uninstall ────────────────────────────────────────────────────────────────

if ($Uninstall) {
    Write-Header "Uninstalling Zag"

    if (Test-Path $ZagHome) {
        Write-Info "Removing $ZagHome..."
        Remove-Item -Recurse -Force $ZagHome
        Write-Success "Zag directory removed."
    } else {
        Write-Warn "Zag is not installed at $ZagHome."
    }

    # Remove from PATH (user-level)
    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
    if ($currentPath -like "*$ZagBinDir*") {
        Write-Info "Removing Zag from user PATH..."
        $newPath = ($currentPath -split ";" | Where-Object { $_ -ne $ZagBinDir }) -join ";"
        [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
        Write-Success "Removed from PATH."
    }

    Write-Success "Zag has been uninstalled."
    Write-Host ""
    Write-Host "  Restart your terminal for PATH changes to take effect."
    exit 0
}

# ── Already installed? ───────────────────────────────────────────────────────

if (-not $Force -and (Test-ZagInstalled)) {
    Write-Header "Zag is already installed"
    Write-Info "To reinstall, run with -Force"
    Write-Info "To uninstall, run with -Uninstall"
    Write-Host ""
    # Surface zig status so the user knows whether .zag builds will work.
    $null = Show-ZigStatus
    exit 0
}

# ── Install ──────────────────────────────────────────────────────────────────

Write-Header "Zag Installer (Windows)"

Write-Info "Platform:    ${OS}-${Arch}"
Write-Info "Version:     ${Version}"
Write-Info "Install to:  ${ZagBinDir}"

# Setup directories
New-Item -ItemType Directory -Force -Path $ZagBinDir | Out-Null

# Download
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
$tmpFile = Join-Path $tmpDir $FileName

Write-Host ""
Write-Info "Downloading ${FileName}..."
Write-Info "  ${DownloadUrl}"

try {
    # Use BITS transfer for better progress and resume support
    Start-BitsTransfer -Source $DownloadUrl -Destination $tmpFile -ErrorAction Stop
} catch {
    # Fallback to Invoke-WebRequest
    try {
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $tmpFile -ErrorAction Stop
    } catch {
        Write-Host ""
        Write-ErrorMsg "Failed to download Zag binary."
        Write-Host ""
        if ($Version -eq "latest") {
            Write-Host "  No release binaries are available yet."
            Write-Host "  You can build from source: https://github.com/$Repo"
        } else {
            Write-Host "  Version '$Version' may not exist. Check available releases:"
            Write-Host "    https://github.com/$Repo/releases"
        }
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        exit 1
    }
}

# Extract
Write-Info "Extracting..."
Expand-Archive -Path $tmpFile -DestinationPath $ZagBinDir -Force -ErrorAction Stop

# Cleanup
Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue

# Verify
$zagExe = Join-Path $ZagBinDir "zag.exe"
if (-not (Test-Path $zagExe)) {
    # Check if it's nested in a subdirectory
    $found = Get-ChildItem -Path $ZagBinDir -Recurse -Filter "zag.exe" | Select-Object -First 1
    if ($found) {
        Move-Item -Force $found.FullName $zagExe
        # Clean up empty dirs
        Get-ChildItem -Path $ZagBinDir -Directory | Where-Object { $_.Name -ne "zag.exe" } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-ErrorMsg "Extracted archive does not contain zag.exe"
        exit 1
    }
}

Write-Success "zag binary installed to ${zagExe}"

# Surface zig toolchain readiness now that zag itself is installed. Warn-only
# (non-fatal): an offline user can fetch zig later and not be blocked on the
# install. Bundled download will resolve the fall-through branch in Step 1.
Write-Host ""
$null = Show-ZigStatus

# ── PATH configuration ───────────────────────────────────────────────────────

if ($SkipPath) {
    Write-Host ""
    Write-Warn "PATH not modified (-SkipPath)."
    Write-Host "  Add this directory to your PATH manually:"
    Write-Host "    ${ZagBinDir}"
    exit 0
}

$currentUserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if (-not $currentUserPath) { $currentUserPath = "" }
if ($currentUserPath -notlike "*$ZagBinDir*") {
    Write-Info "Adding Zag to user PATH..."

    if ($currentUserPath) {
        $newPath = "${currentUserPath};${ZagBinDir}"
    } else {
        $newPath = $ZagBinDir
    }
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")

    # Also update current session
    $env:PATH = "${env:PATH};${ZagBinDir}"
}

Write-Host ""
Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Zag installed successfully!                              ║" -ForegroundColor Green
Write-Host "║                                                           ║" -ForegroundColor Green
Write-Host "║  Restart your terminal or refresh PATH:                   ║" -ForegroundColor Green
Write-Host "║    `$env:Path = [Environment]::GetEnvironmentVariable(    ║" -ForegroundColor Green
Write-Host "║        'PATH', 'User')                                   ║" -ForegroundColor Green
Write-Host "║                                                           ║" -ForegroundColor Green
Write-Host "║  Then try:  zag version                                   ║" -ForegroundColor Green
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
