; Instalador de TK Music para Windows (Inno Setup 6).
; Se arma con windows\installer\build_installer.ps1, que compila la app en
; Release, le suma el runtime de Visual C++ y le pasa la versión del
; pubspec.yaml. A mano:
;   ISCC.exe /DAppVersion=1.0.0 windows\installer\tk_music.iss

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build\installer"
#endif

#define AppName "TK Music"
#define AppExe "tk_music.exe"

[Setup]
; No cambiar el AppId: es lo que hace que una versión nueva actualice la
; instalada en vez de instalarse al lado.
AppId={{017E941F-0B40-4616-83E4-42297CC1DDAB}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=TK Music
AppContact=aloor0781@gmail.com
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Sin permisos de administrador se instala solo para el usuario; con ellos,
; para todos (el instalador pregunta).
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=TK_Music_Setup_{#AppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; Si TK Music está abierto, ofrece cerrarlo antes de actualizar.
CloseApplications=yes
RestartApplications=no
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}
VersionInfoDescription=Instalador de {#AppName}

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; Al actualizar, los recursos de la versión anterior se reemplazan enteros.
Type: filesandordirs; Name: "{app}\data"

[Files]
; La app en Release (exe, DLLs de Flutter, plugins, libmpv y data\) y el
; runtime de Visual C++ que build_installer.ps1 deja al lado del exe.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "*.lib,*.exp,*.pdb,*.ilk"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

; Los datos del usuario (perfiles, favoritos, listas, ajustes) quedan al
; desinstalar: están fuera de la carpeta de la app.
