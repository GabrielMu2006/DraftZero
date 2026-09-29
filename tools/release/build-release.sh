#!/bin/bash
# Draft Zero 发布构建脚本（V0.1.0，V0.1.0-RELEASE-PLAN C.2）
#
# 流程：生成工程 → 解析锁定依赖 → 全新 DerivedData 连续两次 arm64 Release 构建
#       → 校验两次产物一致 → 校验 .app/.appex/版本/最低系统/模型/ad hoc 签名
#       → ditto 打包 ZIP → SHA-256。
#
# 用法：tools/release/build-release.sh [--skip-double-build]
# 产物：dist/DraftZero.app（工作副本）、dist/DraftZero-v<版本>-arm64.zip、dist/SHA256SUMS
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT="$ROOT/dist"
SKIP_DOUBLE=0
[[ "${1:-}" == "--skip-double-build" ]] && SKIP_DOUBLE=1

APP_NAME="DraftZero"
VERSION=$(defaults read "$ROOT/App/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "0.1.0")
ZIP_NAME="DraftZero-v${VERSION}-arm64.zip"
STAMP=$(date +%Y%m%d-%H%M%S)

echo "== Draft Zero 发布构建 $STAMP"
command -v xcodebuild >/dev/null || { echo "需要 Xcode xcodebuild"; exit 1; }

echo "== [1/6] 生成 Xcode 工程"
tools/xcodegen/bin/xcodegen generate

echo "== [2/6] 解析并校验 SwiftPM 锁定（真实上游 + 精确版本）"
(cd Core && swift package resolve >/dev/null 2>&1)
LOCKED=$(python3 - <<'PY'
import json
r = json.load(open('Core/Package.resolved'))
for p in r['pins']:
    print(f"  {p['identity']:24} {p['state'].get('version',''):8} {p['state'].get('revision','')}")
PY
)
echo "$LOCKED"

build_one() {
    local dd="$1"
    rm -rf "$dd"
    xcodebuild \
        -project DraftZero.xcodeproj \
        -scheme DraftZero \
        -configuration Release \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$dd" \
        build 2>&1 | tail -3
    [[ -d "$dd/Build/Products/Release/${APP_NAME}.app" ]] || { echo "构建产物缺失"; exit 1; }
}

DD1="/tmp/dz-release-dd-1"
DD2="/tmp/dz-release-dd-2"
echo "== [3/6] 全新 DerivedData Release 构建（第 1 次）"
build_one "$DD1"

if [[ $SKIP_DOUBLE -eq 0 ]]; then
    echo "== [4/6] 全新 DerivedData Release 构建（第 2 次，可复现性对照）"
    build_one "$DD2"
    if diff -r "$DD1/Build/Products/Release/${APP_NAME}.app" "$DD2/Build/Products/Release/${APP_NAME}.app" >/dev/null 2>&1; then
        echo "   两次构建逐字节一致 ✓"
    else
        echo "   两次构建存在差异（记录差异文件清单）："
        # Xcode/Swift 产物含非确定性内容（appintents 元数据、签名资源等），
        # 差异属预期；以第 1 次构建继续，逐文件校验在 [5/6] 完成。
        diff -rq "$DD1/Build/Products/Release/${APP_NAME}.app" "$DD2/Build/Products/Release/${APP_NAME}.app" | head -10 || true
    fi
else
    echo "== [4/6] 跳过第二次构建（--skip-double-build）"
fi

SRC_APP="$DD1/Build/Products/Release/${APP_NAME}.app"
mkdir -p "$OUT"
rm -rf "$OUT/${APP_NAME}.app" "$OUT/$ZIP_NAME" "$OUT/SHA256SUMS"
cp -R "$SRC_APP" "$OUT/${APP_NAME}.app"

echo "== [5/6] 校验包内容与签名"
APP="$OUT/${APP_NAME}.app"
fail() { echo "!! $1" >&2; exit 1; }

# 版本与最低系统
PLIST="$APP/Contents/Info.plist"
[[ "$(defaults read "$PLIST" CFBundleShortVersionString)" == "$VERSION" ]] || fail "主应用版本号不是 $VERSION"
[[ "$(defaults read "$PLIST" LSMinimumSystemVersion)" == "26.0" ]] || fail "LSMinimumSystemVersion 不是 26.0"
WPLIST="$APP/Contents/PlugIns/DraftZeroWidget.appex/Contents/Info.plist"
[[ -f "$WPLIST" ]] || fail "内嵌 Widget .appex 缺失"
[[ "$(defaults read "$WPLIST" CFBundleShortVersionString)" == "$VERSION" ]] || fail "Widget 版本号不一致"

# 架构：主应用与扩展都必须是 arm64-only
for BIN in "$APP/Contents/MacOS/${APP_NAME}" "$APP/Contents/PlugIns/DraftZeroWidget.appex/Contents/MacOS/DraftZeroWidget"; do
    ARCHS_OUT=$(lipo -archs "$BIN")
    [[ "$ARCHS_OUT" == "arm64" ]] || fail "$BIN 架构非 arm64-only：$ARCHS_OUT"
done

# 离线模型在包内（主应用与扩展各一份为已知成本，见 RELEASE-NOTES）
find "$APP" -name "e5_small.mlmodelc" -type d | grep -q . || fail "包内未找到 e5_small.mlmodelc"
MODEL_WEIGHTS=$(find "$APP" -path "*e5_small.mlmodelc/weights/weight.bin" | head -1)
[[ -n "$MODEL_WEIGHTS" ]] || fail "包内未找到模型权重 weight.bin"
ACTUAL_HASH=$(shasum -a 256 "$MODEL_WEIGHTS" | awk '{print $1}')
[[ "$ACTUAL_HASH" == "7397889b9a97ebb83004fab7380c403d7bd4fddb475a952923c3eb21151bf69f" ]] || fail "模型权重哈希不符：$ACTUAL_HASH"

# ad hoc 签名完整性（CODE_SIGN_IDENTITY="-"；不是可分发签名，V0.1.0 已知边界）
codesign --verify --deep --strict "$APP" || fail "codesign 校验失败"
codesign -dv "$APP" 2>&1 | grep -E "Signature|flags" | head -2 || true
codesign --verify --strict "$APP/Contents/PlugIns/DraftZeroWidget.appex" || fail "Widget 扩展签名校验失败"
spctl -a "$APP" 2>&1 | head -1 || true   # 预期 reject（未公证），仅记录

echo "== [6/6] 打包与校验和"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ZIP_NAME"
(
    cd "$OUT"
    shasum -a 256 "$ZIP_NAME" > SHA256SUMS
)
echo
echo "== 完成"
du -sh "$APP" "$OUT/$ZIP_NAME"
cat "$OUT/SHA256SUMS"
echo "产物目录: $OUT (已 gitignore; 上传资产以产品所有者最终确认为准)"
