; HTKK Updater — Inno Setup script
; Produces dist\htkk-updater-setup-<ver>.exe from a staged payload\ tree:
;   payload\bin\htkk-launcher.exe + 4 scripts (built by build-release.ps1)
;   payload\7z\7z.exe + 7z.dll
; The installed layout mirrors Install-HtkkUpdater.ps1's: {commonappdata}\HtkkUpdater\{bin,7z}
; Post-install runs the installer with -PayloadDir so task registration,
; shortcut creation, hash verification and HTKK bootstrap stay identical.

#ifndef AppVersion
  #define AppVersion "1.1.5"
#endif

[Setup]
AppId={{8A3F2C1E-6B4D-4E9A-B2F7-1D5C9E0A7B33}
AppName=HTKK Updater
AppVersion={#AppVersion}
AppVerName=HTKK Updater {#AppVersion}
AppPublisher=cosmaxis
AppPublisherURL=https://github.com/cosmaxis/htkk-updater
AppSupportURL=https://github.com/cosmaxis/htkk-updater/issues
DefaultDirName={commonappdata}\HtkkUpdater
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
WizardStyle=modern
WizardImageFile=assets\wizard.bmp
WizardSmallImageFile=assets\wizard-small.bmp
SetupIconFile=..\launcher\assets\htkk.ico
UninstallDisplayIcon={app}\bin\htkk-launcher.exe
UninstallDisplayName=HTKK Updater
VersionInfoVersion={#AppVersion}.0
VersionInfoCompany=cosmaxis
VersionInfoDescription=HTKK Updater Setup
VersionInfoProductName=HTKK Updater
Compression=lzma2/ultra64
SolidCompression=yes
OutputDir=..\dist
OutputBaseFilename=htkk-updater-setup-{#AppVersion}
CloseApplications=yes
CloseApplicationsFilter=htkk-launcher.exe
RestartApplications=no

[Files]
Source: "payload\bin\*"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "payload\7z\*";  DestDir: "{app}\7z";  Flags: ignoreversion

[Run]
; Task registration + shortcuts + hash verify (installer's -PayloadDir path).
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\bin\Install-HtkkUpdater.ps1"" -PayloadDir ""{app}\bin"""; \
  Flags: runhidden waituntilterminated; \
  StatusMsg: "Registering the daily update task..."

[UninstallRun]
; Remove task + shortcuts + leftovers before Inno deletes files.
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\bin\Install-HtkkUpdater.ps1"" -Uninstall"; \
  Flags: runhidden waituntilterminated; RunOnceId: "RemoveHtkkUpdater"

[UninstallDelete]
Type: files; Name: "{commondesktop}\HTKK.lnk"
Type: files; Name: "{userdesktop}\HTKK.lnk"
Type: filesandordirs; Name: "{app}\bin"
Type: filesandordirs; Name: "{app}\7z"
Type: files; Name: "{app}\install.log"
Type: files; Name: "{app}\last-result.json"
