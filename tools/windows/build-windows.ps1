# DraftZero V0.2.0 Windows 打包脚本（在用户 Windows 机的项目根目录内运行）。
#
# 边界（windows-ssh skill / 计划 §6）：
# - 所有输出、缓存、临时文件都落在 $Root（= C:\Users\12926\Documents\DraftZero-WindowsBuild）内；
# - 不安装全局软件、不改注册表/系统设置；
# - 若任何步骤试图写根目录之外，停止并报错（见 Assert-InRoot）。
#
# 步骤：还原（锁定依赖）→ 测试 → dotnet publish win-x64（自包含）→ 组装 app 目录
#       （模型/ICO/NOTICE）→ ISCC 编译安装器 → 输出 SHA256 清单。
# 用法：powershell.exe -NoProfile -NonInteractive -File tools\windows\build-windows.ps1 -Root <根目录> [-IsccExe <路径>]
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$IsccExe = "",
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = [System.IO.Path]::GetFullPath($Root)
if (-not (Test-Path $Root)) { throw "根目录不存在：$Root" }

function Assert-InRoot([string]$path) {
    $full = [System.IO.Path]::GetFullPath($path)
    if (-not $full.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "路径越出项目根目录（拒绝执行）：$full"
    }
}

function Set-InRootEnv([string]$name, [string]$sub) {
    $p = Join-Path $Root $sub
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    Set-Item -Path "env:$name" -Value $p
    return $p
}

# 进程作用域缓存/临时目录全部指向根目录内（计划 §6）
$null = Set-InRootEnv "DOTNET_CLI_HOME" ".cache/dotnet-cli-home"
$null = Set-InRootEnv "NUGET_PACKAGES" ".cache/nuget-packages"
$null = Set-InRootEnv "NUGET_HTTP_CACHE_PATH" ".cache/nuget-http"
$null = Set-InRootEnv "NUGET_PLUGINS_CACHE_PATH" ".cache/nuget-plugins"
$null = Set-InRootEnv "TMP" ".tmp"
$null = Set-InRootEnv "TEMP" ".tmp"
$null = Set-InRootEnv "DOTNET_BUNDLE_EXTRACT_BASE_DIR" ".cache/bundle-extract"
$null = Set-InRootEnv "DOTNET_CLI_TELEMETRY_OPTOUT" "1"
$env:DOTNET_NOLOGO = "1"
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = "1"

$Source = Join-Path $Root "source"
$Input = Join-Path $Root "input"
$PublishDir = Join-Path $Root "publish"
$Artifacts = Join-Path $Root "artifacts"
$Evidence = Join-Path $Root "evidence"
foreach ($d in @($PublishDir, $Artifacts, $Evidence)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Assert-InRoot $d
}
Assert-InRoot $Source
Assert-InRoot $Input

$Log = Join-Path $Evidence "build-log.txt"
function Log([string]$message) {
    $line = "$(Get-Date -Format o) $message"
    Write-Host $line
    Add-Content -Path $Log -Value $line
}

Log "=== DraftZero Windows build start ==="
Log "Root=$Root"

# 0. 输入完整性（P-012 冻结传输：SHA 清单必须匹配）
$manifestPath = Join-Path $Input "INPUT-MANIFEST.json"
if (-not (Test-Path $manifestPath)) { throw "缺少 input/INPUT-MANIFEST.json（冻结清单）" }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
foreach ($file in $manifest.files) {
    $p = Join-Path $Input $file.path
    Assert-InRoot $p
    if (-not (Test-Path $p)) { throw "冻结输入缺失：$($file.path)" }
    $hash = (Get-FileHash -Algorithm SHA256 -Path $p).Hash.ToLowerInvariant()
    if ($hash -ne $file.sha256) {
        throw "冻结输入哈希不符：$($file.path)`n  期望 $($file.sha256)`n  实际 $hash"
    }
    Log "input OK $($file.path) sha256=$($file.sha256.Substring(0,12))…"
}

# 1. 锁定依赖还原（source/win-x64 复原包）
$Solution = Join-Path $Source "Windows\DraftZero.sln"
Assert-InRoot $Solution
Log "dotnet restore (locked)"
& dotnet restore $Solution --locked-mode 2>&1 | Tee-Object -FilePath $Log -Append | Out-Null
if ($LASTEXITCODE -ne 0) { throw "restore 失败（锁定模式）" }

# 2. 测试（项目内隔离工作区）
Log "dotnet test"
$testWorkspace = Join-Path $Root ".tmp\test-workspace"
New-Item -ItemType Directory -Force -Path $testWorkspace | Out-Null
$env:DZ_WORKSPACE_DIR = $testWorkspace
& dotnet test (Join-Path $Source "Windows\tests\DraftZero.Core.Tests\DraftZero.Core.Tests.csproj") `
    --configuration $Configuration --no-restore --logger "console;verbosity=minimal" 2>&1 |
    Tee-Object -FilePath $Log -Append | Out-Null
if ($LASTEXITCODE -ne 0) { throw "dotnet test 失败" }
Log "dotnet test 全部通过"

# 3. 发布（win-x64 自包含；单文件不由 dotnet 处理——安装器负责布局）
Log "dotnet publish win-x64 self-contained"
$AppProject = Join-Path $Source "Windows\src\DraftZero.App\DraftZero.App.csproj"
& dotnet publish $AppProject `
    -c $Configuration -f net10.0-windows10.0.19041.0 `
    -r win-x64 --self-contained true `
    -o $PublishDir `
    -p:PublishSingleFile=false `
    -p:IncludeNativeLibrariesForSelfExtract=false `
    --no-restore 2>&1 | Tee-Object -FilePath $Log -Append | Out-Null
if ($LASTEXITCODE -ne 0) { throw "dotnet publish 失败" }

# 发布产物必须全部落在根目录内（计划 §6 审计点）
$publishChildren = Get-ChildItem -Path $PublishDir
foreach ($child in $publishChildren) {
    if ($child.LinkType) { throw "发布目录含链接：$($child.FullName)" }
}
Log "publish 完成（$($publishChildren.Count) 项）"

# 4. 组装 app 目录：模型 + NOTICE
$AppDir = Join-Path $PublishDir "app"
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
# publish 直接输出到 publish/app（重排：先把文件移进去）
Get-ChildItem -Path $PublishDir -Exclude "app" | Move-Item -Destination $AppDir -Force
$modelDir = Join-Path $AppDir "model"
New-Item -ItemType Directory -Force -Path $modelDir | Out-Null
Copy-Item (Join-Path $Input "model.onnx") (Join-Path $modelDir "model.onnx") -Force
Copy-Item (Join-Path $Input "tokenizer.json") (Join-Path $modelDir "tokenizer.json") -Force
if (Test-Path (Join-Path $Input "THIRD-PARTY-NOTICES.md")) {
    Copy-Item (Join-Path $Input "THIRD-PARTY-NOTICES.md") (Join-Path $AppDir "THIRD-PARTY-NOTICES.md") -Force
}
Log "app 目录组装完成（含 model/ 与声明文件）"

# 5. ISCC 编译安装器
$IssPath = Join-Path $Source "Windows\packaging\DraftZero.iss"
Assert-InRoot $IssPath
if ($IsccExe -eq "") {
    $candidate = Get-ChildItem -Path (Join-Path $Root "tools") -Recurse -Filter "ISCC.exe" `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $candidate) {
        throw "未找到项目内 ISCC.exe。请把 Inno Setup 便携版放在 $Root\tools\ 下（不安装全局）。"
    }
    $IsccExe = $candidate.FullName
}
Assert-InRoot $IsccExe
Log "ISCC = $IsccExe"
$installerOut = Join-Path $Artifacts
& $IsccExe "/DAppDir=$AppDir" "/DOutputDir=$installerOut" $IssPath 2>&1 |
    Tee-Object -FilePath $Log -Append | Out-Null
if ($LASTEXITCODE -ne 0) { throw "ISCC 编译失败" }

# 6. 产物哈希清单
$installer = Get-ChildItem -Path $Artifacts -Filter "*.exe" | Select-Object -First 1
if ($null -eq $installer) { throw "ISCC 未产出安装器" }
$hash = (Get-FileHash -Algorithm SHA256 -Path $installer.FullName).Hash.ToLowerInvariant()
$hashLine = "$hash  $($installer.Name)"
$hashPath = Join-Path $Artifacts "SHA256SUMS"
Set-Content -Path $hashPath -Value $hashLine
Log "installer = $($installer.Name)"
Log "sha256    = $hash"
Log "=== DraftZero Windows build OK ==="

Write-Host ""
Write-Host "安装器：$($installer.FullName)"
Write-Host "SHA256：$hash"
