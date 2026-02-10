# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Git Commit Rules

- **NEVER** add `Co-Authored-By` lines to commit messages. Do not include Claude, Anthropic, or any AI co-author attribution in commits.
- **NEVER** include any email address in commit messages (no `noreply@anthropic.com` or similar).

## Project Overview

This is a **wrapper repository** for building [Screenpipe](https://github.com/screenpipe/screenpipe) from source on Windows. The actual Screenpipe codebase is included as a Git submodule at `screenpipe/`. This repository provides Windows-specific build scripts, prerequisite checking, and CI automation.

**For Screenpipe source code guidance** (file headers, package managers, directory structure), see `screenpipe/CLAUDE.md`.

## Repository Architecture

```
recall/
├── scripts/                     # Build automation (PowerShell)
│   ├── check-screenpipe-prereqs.ps1  # Prerequisite validator/installer
│   └── setup-screenpipe.ps1          # Main build script
├── docs/
│   └── SCREENPIPE-SETUP.md      # Complete build documentation
├── .github/workflows/
│   └── build-screenpipe.yml     # CI: Windows build automation
└── screenpipe/                  # Git submodule → screenpipe/screenpipe
```

**Key Concept**: This repo does NOT contain the application source code. It orchestrates building the `screenpipe/` submodule using Windows-specific tooling (vcpkg, LLVM, Vulkan SDK, etc.).

## Common Commands

### Initial Setup

```powershell
# Add submodule (first time only)
git submodule add https://github.com/screenpipe/screenpipe screenpipe
git submodule update --init --recursive

# Check and auto-install prerequisites
.\scripts\check-screenpipe-prereqs.ps1 -AutoFix
```

### Building

```powershell
# Full build (default: release profile)
.\scripts\setup-screenpipe.ps1

# Fast build (release-dev profile, ~3-5x faster compilation)
.\scripts\setup-screenpipe.ps1 -Fast

# Skip prerequisite check (if already validated)
.\scripts\setup-screenpipe.ps1 -SkipPrereqCheck

# Disable parallel bun install
.\scripts\setup-screenpipe.ps1 -NoParallel
```

**Build Output**: `screenpipe/apps/screenpipe-app-tauri/src-tauri/target/release/bundle/nsis/*.exe`

### Submodule Management

```powershell
# Update to latest upstream
git submodule update --remote screenpipe
git add screenpipe
git commit -m "Update screenpipe to latest"

# Sync to pinned commit (after pulling changes)
git submodule update --init --recursive

# Check current commit
git submodule status
```

### Prerequisite Checking

```powershell
# Check only (no install)
.\scripts\check-screenpipe-prereqs.ps1

# Check and install missing tools
.\scripts\check-screenpipe-prereqs.ps1 -AutoFix

# Set LIBCLANG_PATH only (no winget installs)
.\scripts\check-screenpipe-prereqs.ps1 -Fix

# Quiet mode (used by setup-screenpipe.ps1)
.\scripts\check-screenpipe-prereqs.ps1 -Quiet
```

## Build Pipeline Flow

```
check-screenpipe-prereqs.ps1 → setup-screenpipe.ps1 → Output: NSIS installer .exe
         ↓                             ↓
   Validates/installs:            1. cargo build --bin screenpipe
   - Rust, MSVC, LLVM             2. Copy sidecar binary
   - CMake, vcpkg, FFmpeg         3. bun install (parallel)
   - 7-Zip, wget, UnZip           4. pre_build.js (FFmpeg sidecars)
   - Python (for MKL DLLs)        5. Setup MKL + vcredist DLLs
                                  6. Switch to production config
                                  7. Set RUSTFLAGS + Cargo profile env
                                  8. bun tauri build --features official-build
```

**Key Script Responsibilities**:
- `check-screenpipe-prereqs.ps1`: Validates build environment, optionally installs tools via winget
- `setup-screenpipe.ps1`: Orchestrates the complete build (Rust → Tauri app → installer)

**Automated Steps in `setup-screenpipe.ps1`**:
1. Run prerequisite check (unless `-SkipPrereqCheck`)
2. Auto-initialize submodule if empty
3. Build core Rust binary: `cargo build --profile {release|release-dev} --bin screenpipe`
4. Copy `screenpipe.exe` to Tauri sidecar location (`binaries/screenpipe-{target}.exe`)
5. Run `pre_build.js` (downloads/extracts FFmpeg for Windows)
6. Copy MKL DLLs (Intel OpenMP, required for ONNX)
7. Copy vcredist DLLs (Visual C++ runtime)
8. Switch to production config (`tauri.prod.conf.json` → `tauri.conf.json`)
9. Set `RUSTFLAGS` (`-C target-feature=+crt-static -C link-arg=/LTCG`) and Cargo profile env vars
10. Build Tauri app: `bun tauri build --features official-build`

## Critical Environment Variables

When modifying build scripts or CI, these environment variables are **essential**:

| Variable | Purpose | Value |
|----------|---------|-------|
| `LIBCLANG_PATH` | Required by bindgen (whisper-rs-sys build) | `C:\Program Files\LLVM\bin` |
| `CMAKE_ARGS` | Disable AVX-512 instructions for compatibility | `-DGGML_NATIVE=OFF -DGGML_AVX512=OFF ...` |
| `VCPKG_STATIC_LINKAGE` | Static link vcpkg libraries | `true` |
| `KNF_STATIC_CRT` | Static link C runtime | `1` |
| `RUSTFLAGS` | Static CRT + link-time code generation | `-C target-feature=+crt-static -C link-arg=/LTCG` |
| `CARGO_PROFILE_RELEASE_LTO` | Thin LTO (matches upstream) | `thin` |
| `CARGO_PROFILE_RELEASE_OPT_LEVEL` | Optimization level | `2` |
| `CARGO_PROFILE_RELEASE_CODEGEN_UNITS` | Parallel codegen units | `16` |
| `CARGO_PROFILE_RELEASE_STRIP` | Keep symbols (for debugging) | `none` |
| `CARGO_PROFILE_RELEASE_PANIC` | Abort on panic (smaller binary) | `abort` |

**Common Build Failure**: If `whisper-rs-sys` fails with "Unable to find libclang", `LIBCLANG_PATH` is not set correctly. The workflow and script both set this explicitly.

## GitHub Actions CI

**Workflow**: `.github/workflows/build-screenpipe.yml`

**Triggers**:
- Push to `main`
- Push tags matching `v*` (creates draft release)
- Manual dispatch (Actions → Run workflow)

**Build Steps**: Mirrors local build but installs all dependencies in CI (vcpkg, LLVM, Vulkan SDK, etc.)

**Artifacts**:
- Every run uploads: `screenpipe-installer-windows` (NSIS .exe)
- Tags `v*` create draft GitHub Release with .exe attached

**Key CI Implementation Details**:
- Uses vcpkg for FFmpeg (alternative to `pre_build.js` approach)
- Installs LLVM 10.0.0, Vulkan SDK 1.3.290.0, Python 3.12
- Caches: vcpkg packages, LLVM binaries, Rust target directory
- Runs `setup-screenpipe.ps1` after installing all prerequisites

## Workflow vs Upstream Alignment

This repository's CI workflow is based on Screenpipe's `release-app.yml` (Windows build section). The build now matches upstream for all critical settings (prod config, `--features official-build`, RUSTFLAGS, Cargo profile). Remaining differences:

| Aspect | This Repo | Upstream |
|--------|-----------|----------|
| Build Method | Custom PowerShell script | `tauri-action` GitHub Action |
| Scope | Windows-only | Windows + macOS + Linux matrix |
| FFmpeg | vcpkg + pre_build.js | pre_build.js only |
| Release | Simple GitHub releases | CrabNebula Cloud + Sentry |
| Config | Prod config (auto-swapped by script) | Prod config (explicit `cp` step) |
| Features | `--features official-build` (via script) | `--features official-build` (via tauri-action args) |

**When to sync with upstream**:
- Monitor `screenpipe/.github/workflows/release-app.yml` for changes to:
  - vcpkg commit hash
  - LLVM/Vulkan versions
  - `CMAKE_ARGS` or `RUSTFLAGS`
  - New DLL requirements (beyond MKL/vcredist)

**Tracking Command**: `cd screenpipe && git log --oneline .github/workflows/release-app.yml`

See `WORKFLOW_COMPARISON.md` for detailed analysis.

## Sidecar Architecture

Screenpipe uses Tauri's "external binary" pattern to bundle the Rust CLI with the desktop app:

1. **Build**: `cargo build --bin screenpipe` → `screenpipe/target/release/screenpipe.exe`
2. **Copy**: To `screenpipe/apps/screenpipe-app-tauri/src-tauri/binaries/screenpipe-{target}.exe`
3. **Bundle**: Tauri packages the sidecar into the final installer

**Target Triple**: Detected via `rustc -vV | grep host`, typically `x86_64-pc-windows-msvc`

**Reference**: [Tauri Sidecar Documentation](https://tauri.app/develop/sidecar)

## DLL Bundling (Critical for Deployment)

The installer bundles runtime DLLs to reduce end-user dependencies:

### MKL (Intel OpenMP)
```powershell
# In setup-screenpipe.ps1, lines 182-203
python -m pip install intel-openmp --target temp_omp
# Copy all *.dll from temp_omp to src-tauri/mkl/
```

**Why**: ONNX runtime requires Intel OpenMP. Without these DLLs, the app crashes on machines lacking Intel libraries.

### vcredist (Visual C++ Runtime)
```powershell
# In setup-screenpipe.ps1, lines 171-181
Copy-Item C:\Windows\System32\vcruntime140.dll -Destination src-tauri\vcredist\
Copy-Item C:\Windows\System32\vcruntime140_1.dll ...
Copy-Item C:\Windows\System32\msvcp140.dll ...
```

**Why**: Ensures the app runs on clean Windows installations without requiring user to install Visual C++ Redistributable.

**Verification**: Test built .exe on a clean Windows VM without Visual Studio installed.

## Cargo Build Profiles

Defined in `screenpipe/Cargo.toml`:

- `release` (default): Full optimizations, LTO, strip=true (~15-20 min build)
- `release-dev`: Faster compilation, no LTO, debug=1 (~3-5 min build)

**Usage**: `setup-screenpipe.ps1 -Fast` uses `release-dev` profile.

## Troubleshooting

### Build fails with "libclang not found"
- **Cause**: `LIBCLANG_PATH` not set or LLVM not installed
- **Fix**: Run `.\scripts\check-screenpipe-prereqs.ps1 -AutoFix`
- **Manual**: Install LLVM 10.0.0, set `$env:LIBCLANG_PATH = "C:\Program Files\LLVM\bin"`

### Submodule is empty (no Cargo.toml)
- **Cause**: Submodule not initialized
- **Fix**: `git submodule update --init --recursive`
- **Auto**: `setup-screenpipe.ps1` runs this automatically if detected

### Build succeeds but .exe crashes on startup
- **Cause**: Missing MKL or vcredist DLLs in bundle
- **Fix**: Verify `src-tauri/mkl/*.dll` and `src-tauri/vcredist/*.dll` exist before Tauri build
- **Check**: Script logs show "mkl: N DLL(s)" and "vcredist: N DLL(s)"

### CI build times out after 120 minutes
- **Cause**: Workflow has `timeout-minutes: 120`
- **Fix**: Typical builds complete in 40-60 minutes. If timeout, check for hung processes or network issues.

## Working with the Submodule

**Never modify code inside `screenpipe/` directly.** This is a read-only reference to upstream. Instead:

1. Fork screenpipe/screenpipe on GitHub
2. Point the submodule to your fork
3. Make changes in your fork
4. Update the submodule pointer: `git submodule update --remote screenpipe`

**Submodule Pointer**: The submodule tracks a specific commit. CI builds exactly that commit. To build a different version:
```powershell
cd screenpipe
git checkout <commit-or-tag>
cd ..
git add screenpipe
git commit -m "Pin screenpipe to <version>"
```

## Platform-Specific Notes

This repository is **Windows-only**. For macOS or Linux builds, refer to:
- Upstream: `screenpipe/CONTRIBUTING.md`
- Upstream CI: `screenpipe/.github/workflows/release-app.yml`

The scripts assume Windows PowerShell 5.1+ and use Windows-specific tools (winget, MSVC, vcpkg).

## Documentation References

- **Setup Guide**: `docs/SCREENPIPE-SETUP.md` (architecture, submodule workflow, phase-by-phase setup)
- **Upstream Guide**: `screenpipe/CONTRIBUTING.md` (Windows section for prerequisites)
- **Workflow Analysis**: `WORKFLOW_COMPARISON.md` (CI vs upstream alignment)
- **Upstream CLAUDE.md**: `screenpipe/CLAUDE.md` (source code conventions, package managers, directory structure)
