#!/bin/bash
# 构建 LiveCaption.app（需要 Xcode 16 或更新版本）
set -euo pipefail
cd "$(dirname "$0")"

APP="build/LiveCaption.app"

echo "→ 编译中…（第一次会下载 WhisperKit 源码并编译，需要几分钟）"
swift build -c release --product LiveCaption
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BIN_DIR/LiveCaption" "$APP/Contents/MacOS/LiveCaption"
# 依赖包如果带资源包，一起放进 .app
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# 本地临时签名（ad-hoc），系统权限弹窗需要一个签过名的 .app
codesign --force --sign - "$APP"

echo "✓ 完成：$APP"
echo "  运行：open \"$APP\"   （或拖到「应用程序」文件夹）"
