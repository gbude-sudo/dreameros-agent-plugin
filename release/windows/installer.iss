#ifndef SourceExe
  #define SourceExe "..\..\dist\dreameros-agent.exe"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif
#ifndef AppVersion
  #define AppVersion "0.2.0"
#endif
[Setup]
AppId={{C29DD52D-8E71-4B70-BC51-0B6C90675B18}
AppName=DreamerOS Desktop Agent
AppVersion={#AppVersion}
DefaultDirName={localappdata}\DreamerOS\Agent
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=DreamerOSAgentSetup
Compression=lzma2
SolidCompression=yes
Uninstallable=yes

[Files]
Source: "{#SourceExe}"; DestDir: "{app}"; DestName: "dreameros-agent.exe"; Flags: ignoreversion

[Registry]
Root: HKCU; Subkey: "Software\Classes\dreameros"; ValueType: string; ValueName: ""; ValueData: "URL:DreamerOS Desktop Agent"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\dreameros"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\dreameros\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\dreameros-agent.exe"" connect"

[Run]
Filename: "{app}\dreameros-agent.exe"; Parameters: "install"; Description: "Connect DreamerOS"; Flags: postinstall nowait
