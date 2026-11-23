# HTKK Updater — agent notes

## Repo layout
- `Install-HtkkUpdater.ps1` — main installer (one-liner `irm|iex` and bundled `-PayloadDir` modes; also `-Uninstall`)
- `HtkkUpdater.psm1` — update engine (download/verify/extract/install)
- `Invoke-HtkkUpdate.ps1` — scheduled-task entry point
- `HtkkLauncher.ps1` — legacy WinForms launcher (fallback only)
- `launcher/` — native Rust + Slint launcher (`htkk-launcher.exe`)
- `installer/` — Inno Setup script (`htkk-updater.iss`), wizard assets, `payload/` staging (gitignored)
- `build-release.ps1` — full release pipeline
- `dist/` — built setup artifacts (gitignored)

## Building the launcher
- `cd launcher && cargo build --release`
- Icon + manifest are embedded by `build.rs` via `embed-resource`:
  - MSVC/CI: `rc.exe`/`llvm-rc` (auto-detected)
  - GNU local: probes `x86_64-w64-mingw32-windres`, then `windres` on PATH, then `~\mingw64\bin\windres` (sets `RC` env var). No toolchain found → warning only, exe builds without resources. Set `HTKK_REQUIRE_RESOURCES=1` to fail instead.
- **Version info (VS_VERSION_INFO) is NOT in the .rc** — it's injected post-build by `launcher/embed-resources.ps1` (Win32 `BeginUpdateResource`; also re-injects icon+manifest idempotently — safe to run on any exe).
- `cargo test` needs `~\mingw64\bin` on PATH (`dlltool`/`as` for the windows crate build scripts).

## Release pipeline
`.\build-release.ps1` does: cargo build → embed resources → pin `$LauncherVersion`/`$LauncherSha256` in the installer → stage `installer/payload/` → compile `installer/htkk-updater.iss` → `dist/htkk-updater-setup-<ver>.exe`.
Requires: Rust toolchain, Inno Setup 6 (`winget install JRSoftware.InnoSetup`).

## Inno Setup installer
- Installs to `{commonappdata}\HtkkUpdater` (`bin\`, `7z\`), admin only.
- Post-install runs `Install-HtkkUpdater.ps1 -PayloadDir {app}\bin` — task registration, shortcuts, hash verification and HTKK bootstrap are identical to the one-liner path.
- Uninstall: runs the script with `-Uninstall` first, then Inno removes files/shortcuts/ARP entry.

## Gotchas learned
- PowerShell 5.1: no ternary operator; `0xFEEF04BD`-style hex literals >0x7FFFFFFF parse as negative Int32 (write raw bytes instead); `Set-Content -Encoding UTF8` writes BOM.
- Task Scheduler: `schtasks /change` on an S4U task prompts for a password and hangs on hidden consoles — use COM `RegisterTaskDefinition` (launcher `task.rs`) with an elevated `schtasks` fallback.
- COM `LastRunTime` returns `1999-11-30` (not OLE zero) for never-run tasks on recent builds — treated as "never".
- GitHub `windows-latest` runners include rc.exe; this repo's self-hosted fleet may not — keep `HTKK_REQUIRE_RESOURCES=1` in release CI.
- The exe is unsigned: SmartScreen will warn on the setup.exe and one-liner-downloaded binaries until a cert is added.
