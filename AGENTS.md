# HTTK Updater — agent notes

## Repo layout
- `Install-HttkUpdater.ps1` — main installer (one-liner `irm|iex` and bundled `-PayloadDir` modes; also `-Uninstall`)
- `HttkUpdater.psm1` — update engine (download/verify/extract/install)
- `Invoke-HttkUpdate.ps1` — scheduled-task entry point
- `HttkLauncher.ps1` — legacy WinForms launcher (fallback only)
- `launcher/` — native Rust + Slint launcher (`httk-launcher.exe`)
- `installer/` — Inno Setup script (`httk-updater.iss`), wizard assets, `payload/` staging (gitignored)
- `build-release.ps1` — full release pipeline
- `dist/` — built setup artifacts (gitignored)

## Building the launcher
- `cd launcher && cargo build --release`
- Icon + manifest are embedded by `build.rs` via `embed-resource`:
  - MSVC/CI: `rc.exe`/`llvm-rc` (auto-detected)
  - GNU local: probes `x86_64-w64-mingw32-windres`, then `windres` on PATH, then `~\mingw64\bin\windres` (sets `RC` env var). No toolchain found → warning only, exe builds without resources. Set `HTTK_REQUIRE_RESOURCES=1` to fail instead.
- **Version info (VS_VERSION_INFO) is NOT in the .rc** — it's injected post-build by `launcher/embed-resources.ps1` (Win32 `BeginUpdateResource`; also re-injects icon+manifest idempotently — safe to run on any exe).
- `cargo test` needs `~\mingw64\bin` on PATH (`dlltool`/`as` for the windows crate build scripts).

## Release pipeline
`.\build-release.ps1` does: cargo build → embed resources → pin `$LauncherVersion`/`$LauncherSha256` in the installer → stage `installer/payload/` → compile `installer/httk-updater.iss` → `dist/httk-updater-setup-<ver>.exe`.
Requires: Rust toolchain, Inno Setup 6 (`winget install JRSoftware.InnoSetup`).

## Inno Setup installer
- Installs to `{commonappdata}\HttkUpdater` (`bin\`, `7z\`), admin only.
- Post-install runs `Install-HttkUpdater.ps1 -PayloadDir {app}\bin` — task registration, shortcuts, hash verification and HTTK bootstrap are identical to the one-liner path.
- Uninstall: runs the script with `-Uninstall` first, then Inno removes files/shortcuts/ARP entry.

## Gotchas learned
- PowerShell 5.1: no ternary operator; `0xFEEF04BD`-style hex literals >0x7FFFFFFF parse as negative Int32 (write raw bytes instead); `Set-Content -Encoding UTF8` writes BOM.
- Task Scheduler: `schtasks /change` on an S4U task prompts for a password and hangs on hidden consoles — use COM `RegisterTaskDefinition` (launcher `task.rs`) with an elevated `schtasks` fallback.
- COM `LastRunTime` returns `1999-11-30` (not OLE zero) for never-run tasks on recent builds — treated as "never".
- The self-hosted ARM64 runner has no resource compiler — CI embeds resources post-build via `embed-resources.ps1` (see `Embed resources` steps in both workflows). `HTTK_REQUIRE_RESOURCES=1` is NOT set in CI for that reason.
- The installer fetches `httk-launcher.exe.sha256` from the release at install time (CI-rebuilt exes have different hashes); the committed `$LauncherSha256` pin is only the fallback.
- The exe is unsigned: SmartScreen will warn on the setup.exe and one-liner-downloaded binaries until a cert is added.
