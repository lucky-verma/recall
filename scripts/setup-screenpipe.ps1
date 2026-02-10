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
.PARAMETER NoInstallPrereqs
  If set, do not auto-install missing prerequisites; fail immediately when prereq check fails. By default prereqs are auto-installed (InstallPrereqs = true).
#>
param(
    [switch]$Fast,
    [switch]$NoParallel,
    [switch]$SkipPrereqCheck,
    [switch]$NoInstallPrereqs
)

$InstallPrereqs = -not $NoInstallPrereqs
$ProjectRoot = Split-Path $PSScriptRoot
# Canonical repo per CONTRIBUTING.md: https://github.com/screenpipe/screenpipe
$ScreenpipeRepoUrl = "https://github.com/screenpipe/screenpipe"
$ScreenpipeRoot = Join-Path $ProjectRoot "screenpipe"
$tauriApp = Join-Path $ScreenpipeRoot "apps\screenpipe-app-tauri"

# --- 0. Prerequisite check (source: CONTRIBUTING.md#windows) ---
$tauriApp = Join-Path (Join-Path $ScreenpipeRoot "apps") "screenpipe-app-tauri"

# --- 0. Prerequisite check (source: CONTRIBUTING.md Windows section); auto-fix if missing ---
if (-not $SkipPrereqCheck) {
    $prereqScript = Join-Path (Join-Path $ProjectRoot "scripts") "check-screenpipe-prereqs.ps1"
    if (-not (Test-Path $prereqScript)) {
        Write-Error "scripts/check-screenpipe-prereqs.ps1 not found. See docs/SCREENPIPE-SETUP.md Phase 2."
        exit 1
    }
    & $prereqScript -Quiet
    if ($LASTEXITCODE -ne 0) {
        if ($InstallPrereqs) {
            Write-Host "Prerequisites missing; running auto-fix (winget/Bun install)..." -ForegroundColor Cyan
            & $prereqScript -AutoFix
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Prerequisites still missing after auto-fix. Run: ./scripts/check-screenpipe-prereqs.ps1 -AutoFix in an elevated prompt if needed, then re-run this script."
                exit 1
            }
        }
        else {
            Write-Error "Prerequisites missing. Run: ./scripts/check-screenpipe-prereqs.ps1 -AutoFix (or install manually). See docs/SCREENPIPE-SETUP.md."
            exit 1
        }
    }
    Write-Host "Prerequisites OK." -ForegroundColor Green
}

# --- 0a. Refresh PATH so child processes (bun -> pre_build.js) see 7z, wget, etc. ---
$wgetDir = "C:\wget"
if (Test-Path (Join-Path $wgetDir "wget.exe")) { $env:Path = $wgetDir + ";" + $env:Path }
$sevenZipDirs = @("C:\Program Files\7-Zip", "${env:ProgramFiles(x86)}\7-Zip")
foreach ($sz in $sevenZipDirs) {
    if (Test-Path (Join-Path $sz "7z.exe")) { $env:Path = $sz + ";" + $env:Path; break }
}
$gnuWin32Bin = "${env:ProgramFiles(x86)}\GnuWin32\bin"
if (Test-Path (Join-Path $gnuWin32Bin "unzip.exe")) { $env:Path = $gnuWin32Bin + ";" + $env:Path }

# --- 0b. Submodule presence and init ---
if (-not (Test-Path $ScreenpipeRoot)) {
    Write-Error "Screenpipe submodule not found at '$ScreenpipeRoot'. Run: git submodule add $ScreenpipeRepoUrl screenpipe; git submodule update --init --recursive. See docs/SCREENPIPE-SETUP.md."
    exit 1
}
$hasContent = (Test-Path (Join-Path $ScreenpipeRoot "Cargo.toml")) -and (Test-Path (Join-Path $ScreenpipeRoot "apps"))
if (-not $hasContent) {
    Write-Host "Screenpipe not populated; running git submodule update --init --recursive..." -ForegroundColor Cyan
    Push-Location $ProjectRoot
    try {
        git submodule update --init --recursive
        if ($LASTEXITCODE -ne 0) { throw "git submodule update failed" }
    }
    finally { Pop-Location }
    $hasContent = (Test-Path (Join-Path $ScreenpipeRoot "Cargo.toml")) -and (Test-Path (Join-Path $ScreenpipeRoot "apps"))
}
if (-not $hasContent) {
    Write-Error "Screenpipe directory missing Cargo.toml or apps/. Add submodule: git submodule add $ScreenpipeRepoUrl screenpipe; git submodule update --init --recursive. See docs/SCREENPIPE-SETUP.md."
    exit 1
}

# Cargo profile and build
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

# --- 1b. Build core binary ---
Push-Location $ScreenpipeRoot
try {
    Write-Host "Building screenpipe ($cargoProfile)..." -ForegroundColor Cyan
    cargo build --profile $cargoProfile --bin screenpipe
    if ($LASTEXITCODE -ne 0) {
        Write-Error "cargo build failed. Check Rust/C++/LLVM/FFmpeg. Upstream: CONTRIBUTING.md#windows."
        exit 1
    }
}
finally {
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
$sourceExe = Join-Path (Join-Path (Join-Path $ScreenpipeRoot "target") $targetDir) "screenpipe.exe"
$binariesDir = Join-Path (Join-Path (Join-Path (Join-Path $ScreenpipeRoot "apps") "screenpipe-app-tauri") "src-tauri") "binaries"
$destExe = Join-Path $binariesDir $exeName
if (-not $sourceExe -or -not $binariesDir) {
    Write-Error "Sidecar paths not set (ScreenpipeRoot=$ScreenpipeRoot targetDir=$targetDir). Run from repo root: .\scripts\setup-screenpipe.ps1"
    exit 1
}
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
        # tauri.windows.conf.json expects vcredist\*.dll (release-app.yml copies from System32)
        $srcTauri = Join-Path $tauriApp "src-tauri"
        $vcredistDir = Join-Path $srcTauri "vcredist"
        $sys32 = "C:\Windows\System32"
        New-Item -ItemType Directory -Force -Path $vcredistDir | Out-Null
        Copy-Item (Join-Path $sys32 "vcruntime140.dll") -Destination $vcredistDir -Force -ErrorAction Stop
        Copy-Item (Join-Path $sys32 "vcruntime140_1.dll") -Destination $vcredistDir -Force -ErrorAction SilentlyContinue
        Copy-Item (Join-Path $sys32 "msvcp140.dll") -Destination $vcredistDir -Force -ErrorAction SilentlyContinue
        $dllCount = (Get-ChildItem -Path $vcredistDir -Filter "*.dll" -ErrorAction SilentlyContinue).Count
        if ($dllCount -eq 0) { Write-Error "No vcredist DLLs copied. Install Visual C++ Redistributable (e.g. from VS Build Tools)."; exit 1 }
        Write-Host "vcredist: $dllCount DLL(s) in src-tauri\vcredist" -ForegroundColor Green
        # tauri.windows.conf.json expects mkl\*.dll (release-app.yml: pip install intel-openmp, copy to mkl)
        $mklDir = Join-Path $srcTauri "mkl"
        $mklDlls = Get-ChildItem -Path $mklDir -Filter "*.dll" -ErrorAction SilentlyContinue
        if (-not $mklDlls -or $mklDlls.Count -eq 0) {
            Write-Host "Setting up mkl (Intel OpenMP DLLs for ONNX)..." -ForegroundColor Cyan
            New-Item -ItemType Directory -Force -Path $mklDir | Out-Null
            $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
            if (-not $pythonCmd) { $pythonCmd = Get-Command py -ErrorAction SilentlyContinue }
            $pythonExe = if ($pythonCmd) { $pythonCmd.Source } else { $null }
            $tempOmp = Join-Path $srcTauri "temp_omp"
            try {
                if ($pythonExe) {
                    & $pythonExe -m pip install --upgrade pip 2>$null
                    & $pythonExe -m pip install intel-openmp --target $tempOmp 2>$null
                    Get-ChildItem -Path $tempOmp -Recurse -Filter "*.dll" -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item $_.FullName -Destination $mklDir -Force }
                }
                $mklDlls = Get-ChildItem -Path $mklDir -Filter "*.dll" -ErrorAction SilentlyContinue
                if (-not $mklDlls -or $mklDlls.Count -eq 0) {
                    Write-Error "tauri.windows.conf.json requires mkl\*.dll. Install Python, then run: python -m pip install intel-openmp --target temp_omp; copy *.dll from temp_omp to screenpipe\apps\screenpipe-app-tauri\src-tauri\mkl"
                    exit 1
                }
                Write-Host "mkl: $($mklDlls.Count) DLL(s)" -ForegroundColor Green
            }
            finally {
                if (Test-Path $tempOmp) { Remove-Item -Path $tempOmp -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
        Write-Host "Building Tauri app (bun tauri build)..." -ForegroundColor Cyan
        bun tauri build
        if ($LASTEXITCODE -ne 0) {
            Write-Error "bun tauri build failed. See Tauri and pre_build output above."
            exit 1
        }
        Write-Host "Build completed. Output: $tauriApp\src-tauri\target\release\" -ForegroundColor Green
    }
    finally {
        Pop-Location
    }
