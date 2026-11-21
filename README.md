# HTKK updater for Windows

Keeps Vietnam's HTKK tax application updated to the latest official release, hands-free.

## One-line install (any Windows machine)

Run in PowerShell (it self-elevates):

```powershell
irm https://raw.githubusercontent.com/cosmaxis/htkk-updater/main/Install-HtkkUpdater.ps1 | iex
```

That one command:

- Downloads and verifies the official **7-Zip 26.06** (SHA-256 pinned) used to unpack HTKK releases — no other dependencies.
- Installs **HTKK itself** if missing: discovers the latest release on the official [Cục Thuế page](https://www.gdt.gov.vn/wps/portal/home/hotrokekhai?1dmy&current=true&urile=wcm:path:/gdt+content/sa_gdt/htkk/soft_sup_declare), verifies the installer signature, installs silently.
- Registers a daily **"HTKK Daily Updater"** scheduled task (09:00, SYSTEM) that checks the official page and updates HTKK when a newer signed release exists.
- Creates an **HTKK desktop shortcut for all users** — a small launcher app showing live version, task state, and last update result, with "Open HTKK" and "Check for updates" buttons.

## How updates work

Each run (`Invoke-HtkkUpdate.ps1`):

1. Verifies HTKK is not running and reads the installed version from `HTKK.exe.config`.
2. Scrapes the official page for the newest unambiguous release row and HTTPS download link.
3. Downloads with byte limits, extracts with the pinned 7-Zip, and requires both `HTKK.msi` and `setup.exe` to carry a valid signature from the pinned publisher certificate.
4. Backs up the whole install directory, restores it to a verification copy, and compares SHA-256 manifests — before touching the real install.
5. Uninstalls the registered MSI and installs the new one; aborts safely on reboot-required or failure and reports the backup location.
6. Writes `last-result.json` under `%ProgramData%\HtkkUpdater` (shown by the launcher).

Status values: `Updated`, `Current`, `RebootRequired`, `Error` (with stage + message).

## Safety properties

- No hard-coded versions: the latest release is always discovered from the official page.
- Publisher authenticity is enforced via Authenticode + pinned certificate thumbprint.
- Archive safety: path/link validation, entry count and size limits, trusted-extractor-only extraction.
- Updates blocked while HTKK or its updater processes are running; a global mutex prevents concurrent runs.

## Files

| File | Purpose |
| --- | --- |
| `Install-HtkkUpdater.ps1` | Single-click installer — scripts, 7-Zip, first HTKK install, task, desktop shortcut. `-Uninstall` removes the updater (not HTKK). |
| `Invoke-HtkkUpdate.ps1` | One update run; used by the scheduled task and the launcher's update button. |
| `HtkkUpdater.psm1` | Core module: release discovery, download, extraction, backup/verify, install. |
| `HtkkLauncher.ps1` | Desktop app: live status window + launch + manual update. |
| `Test-HtkkUpdater.ps1` | Offline test suite (20 cases). |

## Uninstall

```powershell
& "$env:ProgramData\HtkkUpdater\bin\Install-HtkkUpdater.ps1" -Uninstall
```

Removes the scheduled task, desktop shortcut, and `%ProgramData%\HtkkUpdater`. HTKK itself is left installed.
