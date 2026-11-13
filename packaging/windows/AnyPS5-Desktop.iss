; AnyPS5 Desktop installer (Inno Setup 6).
;
; Built by build-installer.ps1, which passes the version and the Flutter release folder:
;     ISCC.exe /DAppVersion=0.1.23 /DSourceDir=..\..\build\windows\x64\runner\Release AnyPS5-Desktop.iss
;
; Installs for the current user by default (%LOCALAPPDATA%\Programs\AnyPS5 Desktop, no
; administrator rights); the first page offers an install for all users instead.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
; The file's version property: numbers only, so a nightly's passes its numbers alone.
#ifndef FileVersion
  #define FileVersion AppVersion
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build\installer"
#endif

#define AppName "AnyPS5 Desktop"
#define AppExe "anyps5_desktop.exe"

[Setup]
; The AppId identifies the installation for upgrades and the uninstaller: never change it.
AppId={{6A1F3C2E-5B7D-4E8A-9C41-2D0B7F5E9A13}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Utku Halis
AppPublisherURL=https://github.com/AnyTogether/AnyPS5-Desktop
AppSupportURL=https://github.com/AnyTogether/AnyPS5-Desktop/issues
AppUpdatesURL=https://github.com/AnyTogether/AnyPS5-Desktop/releases
VersionInfoVersion={#FileVersion}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
LicenseFile=..\..\LICENSE
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
OutputDir={#OutputDir}
OutputBaseFilename=AnyPS5-Desktop-Setup-{#AppVersion}-x64
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; A running launcher holds its files open: it is closed (Restart Manager, then the code
; below) before files are replaced or removed.
CloseApplications=force
RestartApplications=no
; .anyps5theme files open with the launcher, which installs the theme.
ChangesAssociations=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "turkish"; MessagesFile: "compiler:Languages\Turkish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; Files of an older version that the new one no longer ships.
Type: filesandordirs; Name: "{app}\data"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Registry]
; .anyps5theme (AnyPS5 theme files, the same as the macOS launcher's): opened with the launcher.
; HKA is the current user's classes for a per-user install, the machine's for all users.
Root: HKA; Subkey: "Software\Classes\.anyps5theme"; ValueType: string; ValueName: ""; ValueData: "AnyPS5.Theme"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\.anyps5theme"; ValueType: string; ValueName: "Content Type"; ValueData: "application/x-anyps5theme"; Flags: uninsdeletevalue
Root: HKA; Subkey: "Software\Classes\AnyPS5.Theme"; ValueType: string; ValueName: ""; ValueData: "AnyPS5 theme"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\AnyPS5.Theme\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"",0"
Root: HKA; Subkey: "Software\Classes\AnyPS5.Theme\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"" ""%1"""
; anyps5:// links open the launcher. The launcher writes the same for the user at start, which
; covers the zip. HKA is the user's classes for a per-user install, the machine's for all users.
Root: HKA; Subkey: "Software\Classes\anyps5"; ValueType: string; ValueName: ""; ValueData: "URL:AnyPS5"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\anyps5"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\anyps5\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"",0"
Root: HKA; Subkey: "Software\Classes\anyps5\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"" ""%1"""

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
; The launcher's own update (Restart Now, or Later at the next launch) runs this installer with
; /VERYSILENT /relaunch=1: the launcher opens again on the new version.
Filename: "{app}\{#AppExe}"; Flags: nowait runasoriginaluser; Check: WizardSilent and RelaunchAsked

[Code]
// Ends a running launcher: asked to close first, then ended if it is still there.
procedure CloseLauncher();
var
  Code: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM {#AppExe}', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Sleep(1500);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM {#AppExe}', '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

// The launcher asked to be opened again after a silent update.
function RelaunchAsked(): Boolean;
begin
  Result := ExpandConstant('{param:relaunch|0}') = '1';
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  CloseLauncher();
  Result := '';
end;

function InitializeUninstall(): Boolean;
begin
  CloseLauncher();
  Result := True;
end;
