#!/usr/bin/env bash
# P-012 冻结与传输：从固定 commit 导出源码包，连同模型与打包脚本传到 Windows 构建根目录。
#
# 用法：tools/windows/freeze-transfer.sh <commit> [windows-alias]
# 边界：远程只写 C:\Users\12926\Documents\DraftZero-WindowsBuild\input 与 \source（skill 边界）。
set -euo pipefail

COMMIT="${1:?用法: freeze-transfer.sh <commit> [alias]}"
ALIAS="${2:-windows}"
REMOTE_ROOT='C:/Users/12926/Documents/DraftZero-WindowsBuild'
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dz-freeze.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

echo "== 冻结 commit =="
git -C "$REPO" cat-file -t "$COMMIT" >/dev/null || { echo "commit 不存在：$COMMIT"; exit 1; }
COMMIT=$(git -C "$REPO" rev-parse "$COMMIT")
echo "COMMIT=$COMMIT"

# 1. 源码包（该 commit 的 Windows 构建所需子集：Windows/ 源码 + 打包脚本 + 声明；
#    不传 Mac 专属资产——模型权重走 LFS，也会触发本机缺失的 git-lfs clean）
echo "== 导出源码包 =="
# ZIP 格式：Windows 端 Expand-Archive（.NET ZipArchive）正确处理 UTF-8 文件名标志；
# Windows 内置 tar.exe 对 UTF-8 中文文件名解码失败（已实测）。
git -C "$REPO" -c filter.lfs.clean=cat -c filter.lfs.smudge=cat -c filter.lfs.process= -c filter.lfs.required=false \
  archive --format=zip --prefix="source/" "$COMMIT" -- Windows tools/windows THIRD-PARTY-NOTICES.md > "$STAGE/source.zip"
SOURCE_SHA=$(shasum -a 256 "$STAGE/source.zip" | awk '{print $1}')
echo "source.tar.gz sha256=$SOURCE_SHA"

# 2. 模型与 tokenizer（按已知哈希核对后从归档复制）
ARCHIVE_MODEL="/Users/gabrielmu/Documents/DraftZero-experiments-2026-09-29/t011-spike/models/e5-small-onnx"
MODEL_SHA_EXPECT="ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665"
TOKENIZER_SHA_EXPECT="0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39"
echo "== 校验模型 =="
MODEL_SHA=$(shasum -a 256 "$ARCHIVE_MODEL/model.onnx" | awk '{print $1}')
TOKENIZER_SHA=$(shasum -a 256 "$ARCHIVE_MODEL/tokenizer.json" | awk '{print $1}')
[ "$MODEL_SHA" = "$MODEL_SHA_EXPECT" ] || { echo "model.onnx 哈希不符"; exit 1; }
[ "$TOKENIZER_SHA" = "$TOKENIZER_SHA_EXPECT" ] || { echo "tokenizer.json 哈希不符"; exit 1; }
cp "$ARCHIVE_MODEL/model.onnx" "$STAGE/model.onnx"
cp "$ARCHIVE_MODEL/tokenizer.json" "$STAGE/tokenizer.json"

# 3. 第三方声明随包（source 包内已含；input 单独留一份给打包脚本核对）
cp "$REPO/THIRD-PARTY-NOTICES.md" "$STAGE/THIRD-PARTY-NOTICES.md"

# 4. input 清单
NOTICES_SHA=$(shasum -a 256 "$STAGE/THIRD-PARTY-NOTICES.md" 2>/dev/null | awk '{print $1}')
cat > "$STAGE/INPUT-MANIFEST.json" <<EOF
{
  "commit": "$COMMIT",
  "files": [
    {"path": "model.onnx", "sha256": "$MODEL_SHA"},
    {"path": "tokenizer.json", "sha256": "$TOKENIZER_SHA"},
    {"path": "THIRD-PARTY-NOTICES.md", "sha256": "$NOTICES_SHA"}
  ]
}
EOF

echo "== 远程准备目录 =="
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$ALIAS" \
  "if not exist \"$REMOTE_ROOT\\input\" mkdir \"$REMOTE_ROOT\\input\" && if not exist \"$REMOTE_ROOT\\source\" mkdir \"$REMOTE_ROOT\\source\""

echo "== 传输 =="
scp -o BatchMode=yes -o StrictHostKeyChecking=yes "$STAGE/source.zip" "$ALIAS:$REMOTE_ROOT/input/source.zip"
scp -o BatchMode=yes -o StrictHostKeyChecking=yes "$STAGE/model.onnx" "$ALIAS:$REMOTE_ROOT/input/model.onnx"
scp -o BatchMode=yes -o StrictHostKeyChecking=yes "$STAGE/tokenizer.json" "$ALIAS:$REMOTE_ROOT/input/tokenizer.json"
scp -o BatchMode=yes -o StrictHostKeyChecking=yes "$STAGE/THIRD-PARTY-NOTICES.md" "$ALIAS:$REMOTE_ROOT/input/THIRD-PARTY-NOTICES.md"
scp -o BatchMode=yes -o StrictHostKeyChecking=yes "$STAGE/INPUT-MANIFEST.json" "$ALIAS:$REMOTE_ROOT/input/INPUT-MANIFEST.json"

echo "== 远程解包源码 =="
# zip 内条目已带 source/ 前缀：解到根目录再并入 source/（buildtools 与 source 平级不被触碰）
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$ALIAS" \
  "cd \"$REMOTE_ROOT\" && powershell.exe -NoProfile -NonInteractive -Command \"if (Test-Path 'source') { Remove-Item -Recurse -Force 'source' }; Expand-Archive -Path 'input/source.zip' -DestinationPath 'staging' -Force; New-Item -ItemType Directory -Force 'source' | Out-Null; Move-Item staging/source/Windows source/Windows; Move-Item staging/source/tools source/tools; Move-Item staging/source/THIRD-PARTY-NOTICES.md source/THIRD-PARTY-NOTICES.md; Remove-Item -Recurse -Force staging; (Get-FileHash -Algorithm SHA256 'input/source.zip').Hash.ToLower()\""

echo "== 远程哈希复核 =="
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$ALIAS" \
  "cd \"$REMOTE_ROOT\" && powershell.exe -NoProfile -NonInteractive -Command \"(Get-FileHash -Algorithm SHA256 'input/model.onnx').Hash.ToLower(); (Get-FileHash -Algorithm SHA256 'input/tokenizer.json').Hash.ToLower()\""

echo "== 完成 =="
echo "源码包 SHA256（Mac）: $SOURCE_SHA"
echo "已在远程 $REMOTE_ROOT/input 放置冻结输入；source/ 已解包为 $COMMIT 的源码。"
echo "下一步：远程运行 tools/windows/build-windows.ps1 -Root '$REMOTE_ROOT'"
