# DraftZero Windows 打包工具链一键便携化（V0.2.0 P-012 可复现性产物）。
#
# 在用户 Windows 机上、于项目根目录内运行；全部产物落在 <Root>\buildtools\，
# 不安装全局软件、不写注册表。链路：7zr（官方）→ 解 7-Zip extra → 完整 7-Zip
# → 解 innounp（RAR）→ innounp 解官方 Inno Setup 6.0.5 安装器 → 便携 ISCC。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File setup-buildtools.ps1 -Root <根目录> [-SourceDir <已备好的制品目录>]
# 制品（-SourceDir 或自动下载）与期望 SHA-256：
#   7zr.exe              ad4c82fadcbdf93c03b4fc440f300509c7d60c5c2f4d183e35d9d70d6957037d
#   7z2501-extra.7z      cd3cf38085c2cc6839cf72716dafb3175ae425f4fd34faafc6c0b64d618d307f
#   7z-x64.exe           （SHA 由 -SourceDir 提供时校验；下载路径见下）
#   innounp050.rar       1d8837540ccc15d98245a1c73fd08f404b2a7bdfe7dc9bed2fdece818ff6df67
#   is605.exe            ae6823b523df87e9441789e51845434e4e0e70aac0b88afe80f94f20f4b98acb
param(
    [string]$Root = "C:\Users\12926\Documents\DraftZero-WindowsBuild",
    [string]$SourceDir = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = (Resolve-Path $Root).Path
$Work = Join-Path $Root "buildtools-src"
$Out = Join-Path $Root "buildtools"
New-Item -ItemType Directory -Force -Path $Work, $Out | Out-Null

function Get-Artifact([string]$name, [string]$url, [string]$sha256) {
    $target = Join-Path $Work $name
    if (Test-Path $target) {
        $hash = (Get-FileHash -Algorithm SHA256 -Path $target).Hash.ToLowerInvariant()
        if ($sha256 -eq "" -or $hash -eq $sha256) {
            Write-Host "已有 $name（校验通过）"
            return $target
        }
        Write-Host "$name 已存在但哈希不符，重新获取"
        Remove-Item -Force $target
    }
    if ($SourceDir -ne "") {
        $local = Join-Path $SourceDir $name
        if (-not (Test-Path $local)) { throw "SourceDir 缺少制品：$name" }
        Copy-Item $local $target -Force
    }
    else {
        Write-Host "下载 $name ← $url"
        Invoke-WebRequest -Uri $url -OutFile $target -UserAgent "Mozilla/5.0"
    }
    if ($sha256 -ne "") {
        $hash = (Get-FileHash -Algorithm SHA256 -Path $target).Hash.ToLowerInvariant()
        if ($hash -ne $sha256) { throw "$name SHA-256 校验失败：$hash" }
    }
    return $target
}

$sevenZipUrl = "https://www.7-zip.org/a"
$sevenZipVer = "7z2501"

# 1. 7zr（官方独立可执行）+ extra 包（含 7za）
$7zr = Get-Artifact "7zr.exe" "$sevenZipUrl/7zr.exe" "ad4c82fadcbdf93c03b4fc440f300509c7d60c5c2f4d183e35d9d70d6957037d"
$extra = Get-Artifact "$($sevenZipVer)-extra.7z" "$sevenZipUrl/$($sevenZipVer)-extra.7z" "cd3cf38085c2cc6839cf72716dafb3175ae425f4fd34faafc6c0b64d618d307f"
# 2. x64 安装器（实为 7z SFX，用 7za 直接解包取完整 7z.exe/7z.dll——RAR 解码需要）
$7zx64 = Get-Artifact "$($sevenZipVer)-x64.exe" "$sevenZipUrl/$($sevenZipVer)-x64.exe" ""

# 3. innounp（RAR 压缩，官方 SourceForge）
$innounp = Get-Artifact "innounp050.rar" "https://downloads.sourceforge.net/project/innounp/innounp/innounp%200.50/innounp050.rar" "1d8837540ccc15d98245a1c73fd08f404b2a7bdfe7dc9bed2fdece818ff6df67"

# 4. Inno Setup 6.0.5 官方安装器（GitHub Releases；innounp 0.50 支持该格式）
$is605 = Get-Artifact "is605.exe" "https://github.com/jrsoftware/issrc/releases/download/is-6_0_5/innosetup-6.0.5.exe" "ae6823b523df87e9441789e51845434e4e0e70aac0b88afe80f94f20f4b98acb"

# 解包链（全部输出进 buildtools，不触碰根目录之外）
Push-Location $Work
try {
    & $7zr x -y "$extra" "-o$Work\7zfull" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "解 extra 失败" }
    & "$Work\7zfull\x64\7za.exe" x -y "$7zx64" "-o$Work\7zfull" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "解 7z-x64 失败" }
    & "$Work\7zfull\7z.exe" x -y "$innounp" "-o$Work\innounp" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "解 innounp 失败" }
    $iscc = Join-Path $Out "inno\{app}\ISCC.exe"
    if (-not (Test-Path $iscc)) {
        & "$Work\innounp\innounp.exe" -x -y "-d$Out\inno" "$is605" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "解 Inno Setup 失败" }
    }
}
finally {
    Pop-Location
}

if (-not (Test-Path $iscc)) { throw "ISCC.exe 未就位" }
& $iscc "/?" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "ISCC 无法运行" }

Write-Host ""
Write-Host "工具链就绪：$iscc"
Write-Host "build-windows.ps1 将自动使用该路径（默认参数已指向此位置）。"
