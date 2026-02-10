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
} catch {}
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
} elseif ($Fix -and -not $llvmSet -and (Test-Path (Join-Path $llvmDir "clang.exe"))) {
    [System.Environment]::SetEnvironmentVariable('LIBCLANG_PATH', $llvmDir, 'User')
    if (-not $Quiet) { Write-Host "[FIX] Set LIBCLANG_PATH to $llvmDir (User)" -ForegroundColor Cyan }
}

# --- FFmpeg (in PATH) - CONTRIBUTING.md: vcpkg ffmpeg or pre_build.js downloads; we check PATH ---
$ffmpegOk = $false
try {
    $null = Get-Command ffmpeg -ErrorAction Stop
    $fv = (ffmpeg -version 2>$null | Select-Object -First 1)
    if ($fv) { $ffmpegOk = $true }
} catch {}
Write-Status $ffmpegOk "FFmpeg (in PATH)"
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
} catch { Write-Status $false "Bun" }
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
} catch { Write-Status $false "Protobuf (protoc)" }
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
