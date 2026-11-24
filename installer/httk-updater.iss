; HTTK Updater — Inno Setup script
; Produces dist\httk-updater-setup-<ver>.exe from a staged payload\ tree:
;   payload\bin\httk-launcher.exe + 4 scripts (built by build-release.ps1)
;   payload\7z\7z.exe + 7z.dll
; The installed layout mirrors Install-HttkUpdater.ps1's: {commonappdata}\HttkUpdater\{bin,7z}
; Post-install runs the installer with -PayloadDir so task registration,
; shortcut creation, hash verification and HTTK bootstrap stay identical.

#ifndef AppVersion
  #define AppVersion "1.1.5"
#endif

[Setup]
AppId={{8A3F2C1E-6B4D-4E9A-B2F7-1D5C9E0A7B33}
AppName=HTTK Updater
AppVersion={#AppVersion}
AppVerName=HTTK Updater {#AppVersion}
AppPublisher=cosmaxis
AppPublisherURL=https://github.com/cosmaxis/httk-updater
AppSupportURL=https://github.com/cosmaxis/httk-updater/issues
DefaultDirName={commonappdata}\HttkUpdater
UsePreviousAppDir=no
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
SetupIconFile=..\launcher\assets\httk.ico
UninstallDisplayIcon={app}\bin\httk-launcher.exe
UninstallDisplayName=HTTK Updater
VersionInfoVersion={#AppVersion}.0
VersionInfoCompany=cosmaxis
VersionInfoDescription=HTTK Updater Setup
VersionInfoProductName=HTTK Updater
Compression=lzma2/ultra64
SolidCompression=yes
OutputDir=..\dist
OutputBaseFilename=httk-updater-setup-{#AppVersion}
CloseApplications=yes
CloseApplicationsFilter=httk-launcher.exe,htkk-launcher.exe
RestartApplications=no

[Files]
Source: "payload\bin\*"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "payload\7z\*";  DestDir: "{app}\7z";  Flags: ignoreversion

[Run]
; Task registration + shortcuts + hash verify (installer's -PayloadDir path).
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\bin\Install-HttkUpdater.ps1"" -PayloadDir ""{app}\bin"""; \
  Flags: runhidden waituntilterminated; \
  StatusMsg: "Registering the daily update task..."

[UninstallRun]
; Remove task + shortcuts + leftovers before Inno deletes files.
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\bin\Install-HttkUpdater.ps1"" -Uninstall"; \
  Flags: runhidden waituntilterminated; RunOnceId: "RemoveHttkUpdater"

[UninstallDelete]
Type: files; Name: "{commondesktop}\HTTK.lnk"
Type: files; Name: "{userdesktop}\HTTK.lnk"
Type: files; Name: "{commondesktop}\HTKK.lnk"
Type: files; Name: "{userdesktop}\HTKK.lnk"
Type: filesandordirs; Name: "{app}\bin"
Type: filesandordirs; Name: "{app}\7z"
Type: files; Name: "{app}\install.log"
Type: files; Name: "{app}\last-result.json"
