# recall

Personal project integrating [Screenpipe](https://github.com/screenpipe/screenpipe) as a Git submodule for local build and context on Windows.

## Structure

```
recall/
├── README.md
├── docs/                    # Documentation
│   └── SCREENPIPE-SETUP.md  # Screenpipe submodule + build (source-backed)
├── scripts/                 # Automation (run from repo root)
│   ├── check-screenpipe-prereqs.ps1
│   └── setup-screenpipe.ps1
└── screenpipe/              # Git submodule → https://github.com/screenpipe/screenpipe
```

- **screenpipe/** — Submodule; clone and update so you stay on the latest codebase.
- **scripts/** — Prerequisite check and build; run from repository root (e.g. `.\scripts\setup-screenpipe.ps1`).
- **docs/** — Setup and reference; see [docs/SCREENPIPE-SETUP.md](docs/SCREENPIPE-SETUP.md).

## Quick start

From the repository root:

1. **Add the Screenpipe submodule** (first time):
   ```powershell
   git submodule add https://github.com/screenpipe/screenpipe screenpipe
   git submodule update --init --recursive
   ```

2. **Check prerequisites:**
   ```powershell
   .\scripts\check-screenpipe-prereqs.ps1
   ```

3. **Build:**
   ```powershell
   .\scripts\setup-screenpipe.ps1
   ```

Full steps, submodule workflow, and source references: **[docs/SCREENPIPE-SETUP.md](docs/SCREENPIPE-SETUP.md)**.
