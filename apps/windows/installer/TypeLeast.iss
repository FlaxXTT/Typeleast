; TypeLeast installer (Inno Setup 6).
; Per-user install (no administrator rights) into %LOCALAPPDATA%\Programs\TypeLeast.
; Built by apps/windows/package.ps1:  iscc /DAppVersion=1.17.0 /DSourceDir=<stage> TypeLeast.iss

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

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\TypeLeast"; Filename: "{app}\TypeLeast.exe"
Name: "{autodesktop}\TypeLeast"; Filename: "{app}\TypeLeast.exe"; Tasks: desktopicon

[Registry]
; The app adds this value itself when "开机自动启动" is on; uninstalling removes it.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "TypeLeast"; Flags: uninsdeletevalue dontcreatekey

[Run]
Filename: "{app}\TypeLeast.exe"; Description: "{cm:LaunchProgram,TypeLeast}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/IM TypeLeast.exe /F"; Flags: runhidden; RunOnceId: "StopTypeLeast"
