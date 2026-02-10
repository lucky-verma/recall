#Requires -Version 5.1
<#
.SYNOPSIS
  Builds Screenpipe (submodule) using the sidecar strategy; validates env and submodule, then builds.
.DESCRIPTION
  Run from repository root: .\scripts\setup-screenpipe.ps1
  Upstream build: CONTRIBUTING.md#windows step 8 (cargo build --release; cd apps/screenpipe-app-tauri; bun install; bun tauri build).
  We add: prereq check, submodule init if needed, parallel bun install, optional release-dev profile, explicit sidecar copy, pre_build.js.
  Sidecar path: Tauri externalBin convention - see https://tauri.app/develop/sidecar
  Cargo profiles: screenpipe/Cargo.toml [profile.release] and [profile.release-dev]
  pre_build: screenpipe/apps/screenpipe-app-tauri/scripts/pre_build.js (FFmpeg/Bun sidecars)
.PARAMETER Fast
  Use profile release-dev (~3-5x faster). Source: Cargo.toml profile.release-dev.
.PARAMETER NoParallel
  Disable parallel bun install.
.PARAMETER SkipPrereqCheck
  Skip running check-screenpipe-prereqs.ps1 (use only if you already validated).
#>
param(
    [switch]$Fast,
    [switch]$NoParallel,
    [switch]$SkipPrereqCheck
)

$ErrorActionPreference = "Stop"
# Project root = parent of scripts/ (so run from repo root: .\scripts\setup-screenpipe.ps1)
$ProjectRoot = Split-Path $PSScriptRoot
# Canonical repo per CONTRIBUTING.md: https://github.com/screenpipe/screenpipe
$ScreenpipeRepoUrl = "https://github.com/screenpipe/screenpipe"
$ScreenpipeRoot = Join-Path $ProjectRoot "screenpipe"
$tauriApp = Join-Path $ScreenpipeRoot "apps\screenpipe-app-tauri"

# --- 0. Prerequisite check (source: CONTRIBUTING.md#windows) ---
if (-not $SkipPrereqCheck) {
    $prereqScript = Join-Path $ProjectRoot "scripts\check-screenpipe-prereqs.ps1"
    if (-not (Test-Path $prereqScript)) {
        Write-Error "scripts\check-screenpipe-prereqs.ps1 not found. See docs\SCREENPIPE-SETUP.md Phase 2."
        exit 1
    }
    & $prereqScript -Quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Prerequisites missing. Run: .\scripts\check-screenpipe-prereqs.ps1 and install missing tools. See docs\SCREENPIPE-SETUP.md."
        exit 1
    }
    Write-Host "Prerequisites OK." -ForegroundColor Green
}

# --- 0b. Submodule presence and init (stay in context of latest: submodule) ---
if (-not (Test-Path $ScreenpipeRoot)) {
    Write-Error "Screenpipe submodule not found at '$ScreenpipeRoot'. Run: git submodule add $ScreenpipeRepoUrl screenpipe; git submodule update --init --recursive. See docs\SCREENPIPE-SETUP.md."
    exit 1
}

# Auto-fix: if screenpipe exists but has no content (submodule not populated), init and update
$hasContent = (Test-Path (Join-Path $ScreenpipeRoot "Cargo.toml")) -and (Test-Path (Join-Path $ScreenpipeRoot "apps"))
if (-not $hasContent) {
    Write-Host "Screenpipe not populated; running git submodule update --init --recursive..." -ForegroundColor Cyan
    Push-Location $ProjectRoot
    try {
        git submodule update --init --recursive
        if ($LASTEXITCODE -ne 0) { throw "git submodule update failed" }
    } finally { Pop-Location }
    $hasContent = (Test-Path (Join-Path $ScreenpipeRoot "Cargo.toml")) -and (Test-Path (Join-Path $ScreenpipeRoot "apps"))
}
if (-not $hasContent) {
    Write-Error "Screenpipe directory missing Cargo.toml or apps/. Add submodule: git submodule add $ScreenpipeRepoUrl screenpipe; git submodule update --init --recursive. See docs\SCREENPIPE-SETUP.md."
    exit 1
}

# Cargo profile: release-dev from screenpipe/Cargo.toml
$cargoProfile = if ($Fast) { "release-dev" } else { "release" }
$targetDir = if ($Fast) { "release-dev" } else { "release" }

# --- 1a. Parallel bun install (optional) ---
$bunJob = $null
if (-not $NoParallel -and (Test-Path $tauriApp)) {
    Write-Host "Starting bun install in parallel with Rust build..." -ForegroundColor Cyan
    $bunJob = Start-Job -ScriptBlock {
        Set-Location $using:tauriApp
        bun install 2>&1
    }
}

# --- 1b. Build core binary (CONTRIBUTING.md: cargo build --release) ---
Push-Location $ScreenpipeRoot
try {
    Write-Host "Building screenpipe ($cargoProfile)..." -ForegroundColor Cyan
    cargo build --profile $cargoProfile --bin screenpipe
    if ($LASTEXITCODE -ne 0) {
        Write-Error "cargo build failed. Check Rust/C++/LLVM/FFmpeg. Upstream: CONTRIBUTING.md#windows."
        exit 1
    }
} finally {
    Pop-Location
}

# --- 1c. Wait for bun install ---
$bunInstallOk = $true
if ($bunJob) {
    Wait-Job $bunJob | Out-Null
    $bunInstallOk = ($bunJob.State -eq 'Completed')
    Receive-Job $bunJob | Out-Null
    Remove-Job $bunJob -Force
    if ($bunInstallOk) { Write-Host "bun install completed." -ForegroundColor Green }
    else { Write-Warning "Parallel bun install had issues; will re-run in Tauri step." }
}

# --- 2. Sidecar copy (Tauri externalBin: binaries/<name>-<target_triple>) ---
$rustcOut = (rustc -vV 2>$null) -join " "
if ($rustcOut -match "host:\s*(\S+)") { $target = $Matches[1] } else { $target = "x86_64-pc-windows-msvc" }
$exeName = "screenpipe-$target.exe"
$sourceExe = Join-Path $ScreenpipeRoot "target\$targetDir\screenpipe.exe"
$binariesDir = Join-Path $ScreenpipeRoot "apps\screenpipe-app-tauri\src-tauri\binaries"
$destExe = Join-Path $binariesDir $exeName

if (-not (Test-Path $sourceExe)) {
    Write-Error "Binary not found: $sourceExe. Build may have targeted a different profile/dir."
    exit 1
}
New-Item -ItemType Directory -Force -Path $binariesDir | Out-Null
Copy-Item -Path $sourceExe -Destination $destExe -Force
Write-Host "Copied sidecar to: $destExe" -ForegroundColor Green

# --- 3. Tauri app (CONTRIBUTING.md: cd apps/screenpipe-app-tauri; bun install; bun tauri build) ---
if (-not (Test-Path $tauriApp)) {
    Write-Error "Tauri app path not found: $tauriApp. Upstream: apps/screenpipe-app-tauri."
    exit 1
}

Push-Location $tauriApp
try {
    if (-not $bunJob -or -not $bunInstallOk) {
        Write-Host "Installing frontend dependencies (bun install)..." -ForegroundColor Cyan
        bun install
        if ($LASTEXITCODE -ne 0) { Write-Error "bun install failed."; exit 1 }
    }
    $preBuildScript = Join-Path $tauriApp "scripts\pre_build.js"
    if (Test-Path $preBuildScript) {
        Write-Host "Running pre_build.js (FFmpeg/Bun sidecars; source: scripts/pre_build.js)..." -ForegroundColor Cyan
        bun run scripts/pre_build.js
        if ($LASTEXITCODE -ne 0) { Write-Warning "pre_build.js exited non-zero; continuing." }
    }
    Write-Host "Building Tauri app (bun tauri build)..." -ForegroundColor Cyan
    bun tauri build
    if ($LASTEXITCODE -ne 0) {
        Write-Error "bun tauri build failed. See Tauri and pre_build output above."
        exit 1
    }
    Write-Host "Build completed. Output: $tauriApp\src-tauri\target\release\" -ForegroundColor Green
} finally {
    Pop-Location
}
