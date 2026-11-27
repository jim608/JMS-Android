#define SourcePath ".."

#ifndef JMS_BUNDLE
  #define JMS_BUNDLE "..\build\windows\x64\runner\Release"
#endif

#ifndef JMS_VERSION
  #define JMS_VERSION "latest"
#endif

#define BundleVersion GetVersionNumbersString(AddBackslash(JMS_BUNDLE) + "jms.exe")
#ifdef JMS_VERSION_CODE
  #define InstallerVersion Copy(BundleVersion, 1, RPos(".", BundleVersion)) + Str(JMS_VERSION_CODE)
#else
  #define InstallerVersion BundleVersion
#endif

[Setup]
AppId={{F5D9A17D-C069-4C53-A7AB-BD37E15BE558}
AppName="JMS"
AppVersion={#JMS_VERSION}
VersionInfoVersion={#InstallerVersion}
VersionInfoProductTextVersion={#JMS_VERSION}
VersionInfoProductName=JMS
AppPublisher="Jim608"
DefaultDirName={localappdata}\Programs\JMS
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputBaseFilename=jms_setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern

SetupLogging=yes
UninstallLogging=yes
UninstallDisplayName="JMS"
UninstallDisplayIcon={app}\jms.exe
SetupIconFile="{#SourcePath}\icons\jms\icon.ico"
LicenseFile="{#SourcePath}\LICENSE"
WizardImageFile={#SourcePath}\assets\windows-installer\jms-installer-100.bmp,{#SourcePath}\assets\windows-installer\jms-installer-125.bmp,{#SourcePath}\assets\windows-installer\jms-installer-150.bmp

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#JMS_BUNDLE}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\JMS"; Filename: "{app}\jms.exe"
Name: "{autodesktop}\JMS"; Filename: "{app}\jms.exe"; Tasks: desktopicon

[Registry]
Root: HKA; Subkey: "Software\Classes\jms"; ValueType: string; ValueName: ""; ValueData: "URL:JMS"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\jms"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\jms\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\jms.exe"",0"
Root: HKA; Subkey: "Software\Classes\jms\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\jms.exe"" ""%1"""

[Run]
Filename: "{app}\jms.exe"; Description: "{cm:LaunchProgram,JMS}"; Flags: nowait postinstall skipifsilent
