# HTKK Updater for Windows

[![tests](https://github.com/cosmaxis/htkk-updater/actions/workflows/test.yml/badge.svg)](https://github.com/cosmaxis/htkk-updater/actions/workflows/test.yml)
[![release](https://img.shields.io/github/v/release/cosmaxis/htkk-updater)](https://github.com/cosmaxis/htkk-updater/releases/latest)
[![license](https://img.shields.io/github/license/cosmaxis/htkk-updater)](LICENSE)
[![platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0A84FF)](https://github.com/cosmaxis/htkk-updater)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)](https://github.com/cosmaxis/htkk-updater)

Keeps Vietnam's **HTKK** tax application updated to the latest official release — hands-free, one command, zero maintenance.

<p align="center">
  <img src="docs/screenshot.png" width="340" alt="HTKK Updater launcher — English">
  &nbsp;&nbsp;
  <img src="docs/screenshot-vi.png" width="340" alt="HTKK Updater launcher — Tiếng Việt">
</p>

## One-line install (any Windows machine)

Run in PowerShell — it self-elevates:

```powershell
irm https://raw.githubusercontent.com/cosmaxis/htkk-updater/main/Install-HtkkUpdater.ps1 | iex
```

That single command:

- Downloads and verifies the official **7-Zip 26.06** (SHA-256 pinned) used to unpack HTKK releases — no other dependencies.
- Installs **HTKK itself** if missing: discovers the latest release on the official [Cục Thuế page](https://www.gdt.gov.vn/wps/portal/home/hotrokekhai?1dmy&current=true&urile=wcm:path:/gdt+content/sa_gdt/htkk/soft_sup_declare), verifies the installer signature, installs silently.
- Registers the daily **"HTKK Daily Updater"** scheduled task (09:00, SYSTEM) that checks for and installs newer signed releases.
- Drops an **HTKK launcher** on the desktop for all users — live status, settings, and manual update checks.

## The launcher

A borderless, rounded, dark desktop app — no Windows chrome:

- **Live status** — installed version, latest release, task state, last check, last update result
- **EN ⇄ VI** — single-click language switch, remembered per user
- **Adjustable schedule** — custom hour picker; Apply updates the daily task (one admin prompt)
- **Open HTKK** / **Check for updates** — one click each

<p align="center">
  <img src="docs/time-picker.png" width="180" alt="Custom daily-time picker">
</p>

## How updates work

Each run (`Invoke-HtkkUpdate.ps1`):

1. Verifies HTKK is not running and reads the installed version from `HTKK.exe.config`.
2. Scrapes the official page for the newest unambiguous release row and HTTPS download link.
3. Downloads with byte limits, extracts with the pinned 7-Zip, and requires both `HTKK.msi` and `setup.exe` to carry a valid signature from the pinned publisher certificate.
4. Backs up the whole install directory, restores it to a verification copy, and compares SHA-256 manifests — **before** touching the real install.
5. Uninstalls the registered MSI and installs the new one; aborts safely on reboot-required or failure and reports the backup location.
6. Writes `last-result.json` under `%ProgramData%\HtkkUpdater` (shown by the launcher).

Status values: `Updated`, `Current`, `RebootRequired`, `Error` (with stage + message).

## Safety properties

- **No hard-coded versions** — the latest release is always discovered from the official page.
- **Publisher authenticity** — Authenticode + pinned certificate thumbprint on both installers.
- **Archive safety** — path/link validation, entry count and size limits, trusted-extractor-only extraction.
- **Failure-safe ordering** — backup and restore-verification complete before the real install is touched; a failed download never reaches the uninstall step.
- **Concurrency** — updates blocked while HTKK or its updater runs; a global mutex prevents concurrent runs.

## Files

| File | Purpose |
| --- | --- |
| `Install-HtkkUpdater.ps1` | Single-click installer — scripts, 7-Zip, first HTKK install, task, desktop shortcut. `-Uninstall` removes the updater (not HTKK). |
| `Invoke-HtkkUpdate.ps1` | One update run; used by the scheduled task and the launcher's update button. |
| `HtkkUpdater.psm1` | Core module: release discovery, download, extraction, backup/verify, install. |
| `HtkkLauncher.ps1` | Desktop launcher: live status window, language toggle, schedule settings. |
| `Test-HtkkUpdater.ps1` | Offline test suite (20 cases) — no HTKK install or network needed. |

## Development

Requirements: Windows 10/11, PowerShell 5.1+. No dependencies beyond a hash-pinned 7-Zip the installer fetches itself.

```powershell
# Run the offline test suite (20 cases, self-contained temp dirs)
.\Test-HtkkUpdater.ps1
```

CI runs the same suite plus a syntax check and a UTF-8 BOM check on every push — see [Actions](https://github.com/cosmaxis/htkk-updater/actions).

> **Note:** `HtkkLauncher.ps1` must keep its UTF-8 BOM — without it, Windows PowerShell 5.1 misreads the Vietnamese strings. CI enforces this.

## Contributing

Issues and pull requests welcome. Please keep changes dependency-free (stock PowerShell + WinForms) and make sure `Test-HtkkUpdater.ps1` stays green.

## Uninstall

```powershell
& "$env:ProgramData\HtkkUpdater\bin\Install-HtkkUpdater.ps1" -Uninstall
```

Removes the scheduled task, desktop shortcut, and `%ProgramData%\HtkkUpdater`. HTKK itself is left installed.

## License

[MIT](LICENSE) © 2026 Cosmaxis
