; TypeLeast installer (Inno Setup 6).
; Per-user install (no administrator rights) into %LOCALAPPDATA%\Programs\TypeLeast.
; Built by apps/windows/package.ps1:  iscc /DAppVersion=1.24.5 /DSourceDir=<stage> TypeLeast.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist\stage"
#endif
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif

[Setup]
AppId={{1E95D4F9-E355-487A-BEEA-B05346DEC899}
AppName=TypeLeast
AppVersion={#AppVersion}
AppVerName=TypeLeast {#AppVersion}
AppPublisher=TypeLeast
DefaultDirName={localappdata}\Programs\TypeLeast
DefaultGroupName=TypeLeast
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=TypeLeast-{#AppVersion}-Windows-x64-Setup
SetupIconFile=..\TypeLeast\Assets\TypeLeast.ico
UninstallDisplayIcon={app}\TypeLeast.exe
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Windows 10 1809 or later; Windows 11 is the target.
MinVersion=10.0.17763
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
#if FileExists(CompilerPath + "Languages\ChineseSimplified.isl")
Name: "zh"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#endif

[CustomMessages]
en.RemoveUserData=Also remove your TypeLeast data from this computer?%n%nSettings, dictation history, saved recordings, downloaded speech models and the API keys saved in Windows Credential Manager will be deleted. Choose No to keep them for a later reinstall.
#if FileExists(CompilerPath + "Languages\ChineseSimplified.isl")
zh.RemoveUserData=是否同时删除这台电脑上的 TypeLeast 数据？%n%n会删除设置、听写历史、保存的录音、下载的语音模型，以及保存在 Windows 凭据管理器里的 API Key。选「否」则保留，以后重新安装还能用。
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\TypeLeast"; Filename: "{app}\TypeLeast.exe"
Name: "{autodesktop}\TypeLeast"; Filename: "{app}\TypeLeast.exe"; Tasks: desktopicon

[Registry]
; The app adds this value itself when "登录启动" is on; uninstalling removes it, and the
; mark Windows keeps when the user switches it off in Task Manager.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "TypeLeast"; Flags: uninsdeletevalue dontcreatekey
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"; ValueType: none; ValueName: "TypeLeast"; Flags: uninsdeletevalue dontcreatekey

[Run]
Filename: "{app}\TypeLeast.exe"; Description: "{cm:LaunchProgram,TypeLeast}"; Flags: nowait postinstall skipifsilent
; An in-app update runs this installer silently with /RELAUNCH=1: start the new version again.
Filename: "{app}\TypeLeast.exe"; Flags: nowait runasoriginaluser; Check: RelaunchRequested

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/IM TypeLeast.exe /F /T"; Flags: runhidden; RunOnceId: "StopTypeLeast"

[Code]
function RelaunchRequested: Boolean;
begin
  Result := WizardSilent and (ExpandConstant('{param:RELAUNCH|0}') = '1');
end;

// Before the files go: close TypeLeast (and its local service) and, if the user agrees,
// let the app delete its data. A silent uninstall keeps the data.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Code: Integer;
begin
  if CurUninstallStep <> usUninstall then exit;
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/IM TypeLeast.exe /F /T', '', SW_HIDE, ewWaitUntilTerminated, Code);
  if UninstallSilent then exit;
  if MsgBox(CustomMessage('RemoveUserData'), mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    Exec(ExpandConstant('{app}\TypeLeast.exe'), '--remove-user-data', '', SW_HIDE, ewWaitUntilTerminated, Code);
end;
