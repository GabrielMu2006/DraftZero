; DraftZero V0.2.0 — 每用户安装器（Inno Setup 6）
;
; 决定项（计划 §2/§4 W-012）：
; - PrivilegesRequired=lowest：每用户安装，无需管理员；
; - 稳定 AppId：升级（同 AppId 新版本）保留用户数据；卸载默认保留数据（Uninstallable=yes,
;   不加任何 Delete 数据项）；
; - 自带 .NET runtime（self-contained publish）、原生库、离线模型随包；
; - 注册 draftzero:// 协议（HKCU）；
; - 卸载时不删除 %LocalAppData%\DraftZero（用户工作区）。
; - 未经签名分发（预览版）：安装说明须如实写明 SmartScreen 提示。

#define MyAppName "Draft Zero"
#define MyAppVersion "0.2.1"
#define MyAppPublisher "GabrielMu"
#define MyAppExeName "DraftZero.exe"
#ifndef AppDir
#define AppDir "app"
#endif
#ifndef OutputDir
#define OutputDir "artifacts"
#endif

[Setup]
AppId={{8C6B3E1A-52B7-4A63-9F4D-2A5C8E0D1D30}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}（Windows 预览版）
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\DraftZero
; 每用户：PrivilegesRequired=lowest 时 {autopf} 解析为 %LocalAppData%\Programs
PrivilegesRequired=lowest
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=DraftZero-Setup-v{#MyAppVersion}-win-x64
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64
UninstallDisplayIcon={app}\{#MyAppExeName}
; 未签名：保留真实提示，不在脚本里关闭任何系统保护
SetupLogging=yes

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Files]
; 应用与运行时（self-contained publish 输出全部内容）
Source: "{#AppDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式(&D)"; GroupDescription: "附加任务："

[Registry]
; draftzero:// 协议（仅 HKCU，用户级；配合应用内确认弹窗，见 W-009）
Root: HKCU; Subkey: "Software\Classes\draftzero"; ValueType: string; ValueData: "URL:Draft Zero Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\draftzero"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\draftzero\DefaultIcon"; ValueType: string; ValueData: "{app}\{#MyAppExeName},0"
Root: HKCU; Subkey: "Software\Classes\draftzero\shell\open\command"; ValueType: string; ValueData: """{app}\{#MyAppExeName}"" ""%1"""

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; 无：卸载不删除任何用户数据（%LocalAppData%\DraftZero 原样保留）

[UninstallDelete]
; 无 Delete 条目：升级保留数据；卸载默认保留数据（W-012）

[Messages]
SetupAppTitle={#MyAppName} {#MyAppVersion} 安装向导
WelcomeLabel2=这将安装 [name/ver] 到你的账户（无需管理员）。%n%n安装内容包含离线语义模型（约 470 MB），全部数据保存在本机。%n%n本安装包未经代码签名，Windows SmartScreen 可能显示提示——选择「仍要运行」继续；请不要为此全局关闭系统保护。
FinishedLabelNoIcons=[name] 已安装到你的账户。%n%n数据将保存在 %LocalAppData%\DraftZero；卸载不会删除这些数据。
