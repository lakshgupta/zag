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

# ── Check ────────────────────────────────────────────────────────────────────

function Test-ZagInstalled {
    $zag = Join-Path $ZagBinDir "zag.exe"
    return (Test-Path $zag)
}

if ($Check) {
    if (Test-ZagInstalled) {
        $zag = Join-Path $ZagBinDir "zag.exe"
        Write-Host "zag is installed at $zag"
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
