# HTKK updater for Windows

## Goal

Create a Windows script that keeps Vietnam's HTKK tax application updated to the latest release. The user cited 5.8.4 as the current example; do not hard-code that version. The intended outcome is an actual update, not just a version notification or download. Define unattended scheduling and any unavoidable user interaction after checking the real installer and Windows environment.

## Status — 2026-11-20

**Handoff only. No updater has been written, installed, or tested.** No Windows PC was accessible in the investigating session. No changes were made to a Windows installation or tax data.

The previous assistant suggested opening HTKK online and accepting its update prompt if one appears. Whether the installed HTKK version offers that prompt, its behavior, and whether it can be automated remain unverified. Investigate the application's own updater first; prefer it if it safely meets the goal.

## Verified findings

- The [Cục Thuế HTKK page](https://www.gdt.gov.vn/wps/portal/home/hotrokekhai?1dmy&current=true&urile=wcm:path:/gdt+content/sa_gdt/htkk/soft_sup_declare) listed version **5.8.4**, released 18 November 2026, ahead of 5.8.3 and earlier releases. The [official notice](https://www.gdt.gov.vn/wps/portal/home/hotrokekhai?1dmy&page=Z6_049IL8VSO3VHF0I1AMGLAN31M6&urile=wcm%3apath%3a%2Fgdt%2Bcontent%2Fsa_gdt%2Fhtkk%2Finfo_sup_declare%2Fe21c90b4-6b2e-4cde-b110-2e73e6532aaa) says 5.8.4 applies from 19 November 2026 and points users to the government download page.
- The 5.8.4 table row labels its installer link `ZIP`, but links to [Fshare](https://www.fshare.vn/file/JT65WVCUY1WA). On this machine, `curl -L` followed redirects and downloaded a RAR 5 archive named `HTKK_v5.8.4_DLL_signed.rar` (about 90 MB). Future releases can use a different link or delivery flow; discover it from the official page rather than constructing or hard-coding it. Download redirects contained temporary URLs; do not save or depend on them.
- Archive listing contained `setup.exe`, `HTKK.msi`, `Data1.cab`, `Setup.ini`, and .NET Framework 3.5 prerequisite files. `Setup.ini` identifies `Product=HTKK`, `PackageName=HTKK.msi`, and `ProductVersion=4.2.2` even though the archive is 5.8.4. Installer metadata therefore needs investigation before it is used to determine the application release. This observation is about that file only, not every possible version indicator.
- The suggested hostname `hotrokekhai.gdt.gov.vn` did not resolve during this session. The official `www.gdt.gov.vn` page above did load in the web reader; a subsequent command-line fetch timed out. The upstream site and Fshare behavior need robust failure reporting, not assumptions.
- `pwsh` and a Windows runtime were unavailable locally. No PowerShell, archive extraction on Windows, signature validation, backup, upgrade, scheduling, rollback, or end-to-end behavior was tested.

## Risks and unknowns

- **Tax data:** Determine the actual installed application and data locations, including any non-default location. Verify a restorable backup before attempting an update; do not overwrite or delete user data or force-close HTKK. Prevent updates while HTKK is running and handle races with launches.
- **Installer:** Determine supported Windows versions, prerequisites, elevation, existing-install upgrade behavior, silent flags, and return codes on a disposable Windows installation. `Setup.ini` alone does not establish any of these. Do not assume `/S` works.
- **Authenticity:** Establish how to verify the package/installer against a trustworthy publisher signature or authoritative checksum. An official page linking to third-party hosting is not by itself an integrity check. Fail safely if authenticity cannot be established.
- **Archive:** The observed package is RAR 5, not ZIP. Determine how to extract it on the supported Windows versions without silently relying on a missing or unsafe tool. Avoid unsafe archive paths.
- **Updates:** Identify a reliable installed-release indicator and compare versions correctly. Handle network failures, changes to page format or host, unavailable releases, already-current installations, partial downloads, and install failures without reporting success.
- **Automation:** The user requested automatic updates, but the schedule, permissions, interactive prompts, and exact target environment have not been established. Use a safe default where evidence supports one; surface a genuine blocker or material choice rather than silently reducing the scope.

## Continuation plan

1. Obtain access to a disposable Windows test environment and inspect a real HTKK install: app and data paths, release indicator, existing updater, process names, and backup/restore procedure. Keep real taxpayer data out of tests.
2. Verify the official release-page structure and latest-version discovery, Fshare download behavior, archive extraction, and authenticity checks. Include checks for changed page structure and failures.
3. Determine and test the supported upgrade procedure, prerequisites, permissions, and successful/failing exit behavior. Verify backup and restore before testing destructive scenarios.
4. Implement the smallest complete Windows updater, with a reliable automatic trigger and clear failure reporting. Never force-close the app or claim an update succeeded without checking the installed result.
5. Test an upgrade from an older release, already-current behavior, running-app behavior, failures and recovery, and preservation/restoration of representative test data. Document installation, scheduling, prerequisites, and operational limitations.

Do not stage, commit, push, or create a remote without the user's explicit approval.
