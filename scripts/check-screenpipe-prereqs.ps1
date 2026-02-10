#Requires -Version 5.1
<#
.SYNOPSIS
  Validates Windows environment for building Screenpipe; suggests or applies fixes.
.DESCRIPTION
  Checks Rust, C++ Build Tools, LLVM/Clang, FFmpeg, Bun, and protoc per upstream:
  https://github.com/screenpipe/screenpipe/blob/main/CONTRIBUTING.md#windows
  Exit codes: 0 = all OK, 1 = one or more missing (install commands printed).
  Run from repository root: .\scripts\check-screenpipe-prereqs.ps1
.PARAMETER Fix
  When possible, set User env vars (e.g. LIBCLANG_PATH) without prompting. Does not run winget/choco.
.PARAMETER Quiet
  Only print missing tools and install commands; no [OK] lines. Use from other scripts.
#>
param(
    [switch]$Fix,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$script:ExitCode = 0
$script:Missing = [System.Collections.ArrayList]@()
$wingetCmds = @()
$chocoCmds = @()

function Write-Status($ok, $msg) {
    if ($Quiet -and $ok) { return }
    if ($ok) { Write-Host "[OK] $msg" -ForegroundColor Green }
    else { Write-Host "[MISSING] $msg" -ForegroundColor Yellow; $script:ExitCode = 1 }
}

# --- Rust (cargo, rustc) - CONTRIBUTING.md Windows step 2: Rustlang.Rustup ---
$rustOk = $false
try {
    $cargoExe = Get-Command cargo -ErrorAction Stop
    $rustcExe = Get-Command rustc -ErrorAction Stop
    $cv = (cargo --version 2>$null)
    $rv = (rustc --version 2>$null)
    if ($cv -and $rv) {
        $rustOk = $true
        Write-Status $true "Rust: $($cv -join ' ')"
    }
    # CMake (Kitware) often installs here; winget may not refresh current session PATH
    $cmakeBin = "C:\Program Files\CMake\bin"
    if (Test-Path (Join-Path $cmakeBin "cmake.exe")) { $env:Path = $cmakeBin + ";" + $env:Path }
    # GnuWin32 (unzip etc.) - CONTRIBUTING.md step 4
    $gnuWin32Bin = "${env:ProgramFiles(x86)}\GnuWin32\bin"
    if (Test-Path (Join-Path $gnuWin32Bin "unzip.exe")) { $env:Path = $gnuWin32Bin + ";" + $env:Path }
    # wget (pre_build.js downloads FFmpeg) - same location as release-app.yml
    $wgetDir = "C:\wget"
    if (Test-Path (Join-Path $wgetDir "wget.exe")) { $env:Path = $wgetDir + ";" + $env:Path }
    # 7-Zip (pre_build.js extracts FFmpeg .7z)
    $sevenZipPaths = @("C:\Program Files\7-Zip", "${env:ProgramFiles(x86)}\7-Zip")
    foreach ($sz in $sevenZipPaths) {
        if (Test-Path (Join-Path $sz "7z.exe")) { $env:Path = $sz + ";" + $env:Path; break }
    }
}
catch {}
if (-not $rustOk) {
    Write-Status $false "Rust (cargo, rustc)"
    $wingetCmds += "winget install -e --id Rustlang.Rustup"
    $chocoCmds += "choco install rust -y"
}

# --- C++ Build Tools - CONTRIBUTING.md Windows step 2: Microsoft.VisualStudio.2022.BuildTools ---
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasCpp = $false
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($vsPath) { $hasCpp = $true }
}
Write-Status $hasCpp "C++ Build Tools (VS Build Tools with C++ workload)"
if (-not $hasCpp) {
    $wingetCmds += "winget install -e --id Microsoft.VisualStudio.2022.BuildTools --override `"--wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended`""
    $chocoCmds += "choco install visualstudio2022buildtools visualstudio2022-workload-vctools -y"
}

# --- LLVM/Clang - CONTRIBUTING.md Windows step 2 + 4: LLVM.LLVM, LIBCLANG_PATH ---
$llvmDir = "C:\Program Files\LLVM\bin"
$llvmSet = $env:LIBCLANG_PATH
$llvmExists = (Test-Path (Join-Path $llvmDir "clang.exe")) -or ($llvmSet -and (Test-Path (Join-Path $llvmSet "clang.exe")))
Write-Status $llvmExists "LLVM/Clang"
if (-not $llvmExists) {
    $wingetCmds += "winget install -e --id LLVM.LLVM"
    $chocoCmds += "choco install llvm -y"
}
elseif ($Fix -and -not $llvmSet -and (Test-Path (Join-Path $llvmDir "clang.exe"))) {
    [System.Environment]::SetEnvironmentVariable('LIBCLANG_PATH', $llvmDir, 'User')
    if (-not $Quiet) { Write-Host "[FIX] Set LIBCLANG_PATH to $llvmDir (User)" -ForegroundColor Cyan }
}

# --- FFmpeg (in PATH) - CONTRIBUTING.md: vcpkg ffmpeg or pre_build.js downloads; we check PATH ---
$ffmpegOk = $false
try {
    $null = Get-Command ffmpeg -ErrorAction Stop
    $fv = (ffmpeg -version 2>$null | Select-Object -First 1)
    if ($fv) { $ffmpegOk = $true }
}
catch {}
Write-Status $ffmpegOk "FFmpeg (in PATH)"
# --- CMake (required by whisper-rs-sys and other crates) - CONTRIBUTING.md step 2: Kitware.CMake ---
$cmakeOk = $false
try {
    $null = Get-Command cmake -ErrorAction Stop
    $cmv = (cmake --version 2>$null | Select-Object -First 1)
    if ($cmv) { $cmakeOk = $true; Write-Status $true "CMake: $($cmv -join ' ')" } else { Write-Status $false "CMake" }
}
catch { Write-Status $false "CMake" }
if (-not $cmakeOk) {
    $script:Missing.Add(@{ Name = "CMake"; WingetId = "Kitware.CMake" }) | Out-Null
}

# --- UnZip (GnuWin32) - required by screenpipe-audio build.rs - CONTRIBUTING.md step 2: GnuWin32.UnZip ---
$unzipOk = $false
try {
    $null = Get-Command unzip -ErrorAction Stop
    $uzv = (unzip -v 2>$null | Select-Object -First 1)
    if ($uzv) { $unzipOk = $true; Write-Status $true "UnZip (GnuWin32)" } else { Write-Status $false "UnZip (GnuWin32)" }
}
catch { Write-Status $false "UnZip (GnuWin32)" }
if (-not $unzipOk) {
    $script:Missing.Add(@{ Name = "UnZip (GnuWin32)"; WingetId = "GnuWin32.UnZip" }) | Out-Null
}

# --- Wget (pre_build.js downloads Windows FFmpeg) - release-app.yml uses C:\wget ---
$wgetOk = $false
$wgetPaths = @(
    "C:\wget\wget.exe",
    "${env:ProgramFiles(x86)}\GnuWin32\bin\wget.exe",
    "C:\Program Files\Git\mingw64\bin\wget.exe",
    "C:\msys64\usr\bin\wget.exe"
)
foreach ($wp in $wgetPaths) {
    if (Test-Path $wp) {
        try {
            $null = & $wp --version 2>$null
            if ($LASTEXITCODE -eq 0) { $wgetOk = $true; break }
        }
        catch {}
    }
}
if (-not $wgetOk) {
    $cmd = Get-Command wget.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        try {
            $null = & $cmd.Source --version 2>$null
            if ($LASTEXITCODE -eq 0) { $wgetOk = $true }
        }
        catch {}
    }
}
Write-Status $wgetOk "Wget (pre_build.js)"
if (-not $wgetOk) {
    $script:Missing.Add(@{ Name = "Wget"; WingetId = $null; InstallScript = "Wget" }) | Out-Null
}

# --- 7-Zip (pre_build.js extracts FFmpeg .7z) ---
$sevenZipOk = $false
$sevenZipPaths = @("C:\Program Files\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe")
foreach ($sz in $sevenZipPaths) {
    if (Test-Path $sz) {
        try {
            $null = & $sz 2>$null
            if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 7) { $sevenZipOk = $true; break }
        }
        catch {}
    }
}
if (-not $sevenZipOk) {
    $cmd = Get-Command 7z -ErrorAction SilentlyContinue
    if ($cmd) {
        try {
            $null = & $cmd.Source 2>$null
            if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 7) { $sevenZipOk = $true }
        }
        catch {}
    }
}
Write-Status $sevenZipOk "7-Zip (pre_build.js)"
if (-not $sevenZipOk) {
    $script:Missing.Add(@{ Name = "7-Zip"; WingetId = "7zip.7zip" }) | Out-Null
}

if (-not $ffmpegOk) {
    $wingetCmds += "winget install -e --id Gyan.FFmpeg"
    $chocoCmds += "choco install ffmpeg -y"
}

# --- Bun - CONTRIBUTING.md Windows step 2: irm https://bun.sh/install.ps1 | iex ---
$bunOk = $false
try {
    $null = Get-Command bun -ErrorAction Stop
    $bv = (bun --version 2>$null)
    if ($bv) { $bunOk = $true; Write-Status $true "Bun: $bv" } else { Write-Status $false "Bun" }
}
catch { Write-Status $false "Bun" }
if (-not $bunOk) {
    $wingetCmds += "irm https://bun.sh/install.ps1 | iex"
    $chocoCmds += "choco install bun -y"
}

# --- Protobuf (protoc) - often required by Rust crates ---
$protocOk = $false
try {
    $null = Get-Command protoc -ErrorAction Stop
    $pv = (protoc --version 2>$null)
    if ($pv) { $protocOk = $true; Write-Status $true "Protobuf (protoc): $($pv -join ' ')" } else { Write-Status $false "Protobuf (protoc)" }
}
catch { Write-Status $false "Protobuf (protoc)" }
if (-not $protocOk) {
    $wingetCmds += "winget install -e --id Google.Protobuf"
    $chocoCmds += "choco install protobuf -y"
}

# --- Summary ---
Write-Host ""
if ($script:ExitCode -eq 0) {
    if (-not $Quiet) { Write-Host "All required tools are present. Run: .\scripts\setup-screenpipe.ps1" -ForegroundColor Green }
    exit 0
}

Write-Host "--- Install missing tools (see docs\SCREENPIPE-SETUP.md); source: CONTRIBUTING.md#windows ---" -ForegroundColor Cyan
Write-Host ""
Write-Host "winget:" -ForegroundColor White
foreach ($c in $wingetCmds) { Write-Host "  $c" }
Write-Host ""
Write-Host "choco:" -ForegroundColor White
foreach ($c in $chocoCmds) { Write-Host "  $c" }
Write-Host ""
if (-not $Quiet) {
    Write-Host "Optional: set LIBCLANG_PATH after installing LLVM:" -ForegroundColor Gray
    Write-Host "  [System.Environment]::SetEnvironmentVariable('LIBCLANG_PATH', 'C:\Program Files\LLVM\bin', 'User')" -ForegroundColor Gray
    Write-Host "Then restart the terminal and re-run this script." -ForegroundColor Gray
}
exit 1
