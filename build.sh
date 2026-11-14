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
# 应用图标（由 scripts/make-icon.swift 生成）
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 依赖包如果带资源包，一起放进 .app
for bundle in "$BIN_DIR"/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# 签名：系统权限（麦克风 / 语音识别 / 屏幕与系统录音）是按签名认应用的。
# 钥匙串里有本机自签名证书「LiveCaption Local Signing」就用它，这样重新编译后权限还在；
# 没有就退回临时签名（ad-hoc）——能用，但每次重新编译都要重新授权。
# 创建证书的方法见 README。
IDENTITY="LiveCaption Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "→ 已用「$IDENTITY」签名"
else
  codesign --force --sign - "$APP"
  echo "→ 临时签名（ad-hoc）：重新编译后需要重新授权系统权限"
fi

echo "✓ 完成：$APP"

# 「应用程序」里装过的话，顺手更新那一份（第一次安装：./build.sh --install）
INSTALLED="/Applications/LiveCaption.app"
if [ -d "$INSTALLED" ] || [ "${1:-}" = "--install" ]; then
  pkill -x LiveCaption 2>/dev/null && sleep 1 || true
  rm -rf "$INSTALLED"
  ditto "$APP" "$INSTALLED"
  echo "✓ 已安装到 $INSTALLED"
fi
echo "  运行：open \"$APP\"   （或拖到「应用程序」文件夹）"
