#!/bin/bash
# 打一个可以发给别人的安装包：build/LiveCaption-版本号.dmg
#
#   ./scripts/make-dmg.sh
#       没有 Apple 开发者账号时用：临时签名。对方第一次打开会被系统拦下，
#       需要按安装包里「首次打开说明.txt」手动放行一次。
#
#   SIGN_IDENTITY="Developer ID Application: 名字 (TEAMID)" NOTARY_PROFILE=配置名 ./scripts/make-dmg.sh
#       有开发者账号时用：正式签名 + 公证，对方双击就能打开。
#       NOTARY_PROFILE 是事先用 `xcrun notarytool store-credentials 配置名` 存好的凭据。
#
# 不会改动「应用程序」里你自己正在用的那一份。
set -euo pipefail
cd "$(dirname "$0")/.."

export SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NO_INSTALL=1 ./build.sh

APP="build/LiveCaption.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
DMG="build/LiveCaption-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/LiveCaption.app"
ln -s /Applications "$STAGE/应用程序"
if [[ "$SIGN_IDENTITY" != Developer\ ID* ]]; then
  cat > "$STAGE/首次打开说明.txt" <<'TXT'
LiveCaption 安装和首次打开

1. 把 LiveCaption 拖到旁边的「应用程序」文件夹。
2. 在「应用程序」里双击 LiveCaption。系统会提示「无法打开」或「无法验证开发者」，点「完成」。
3. 打开「系统设置 → 隐私与安全性」，往下翻到「安全性」，在 LiveCaption 那一行点「仍要打开」，
   再输入密码确认。只需要这样做一次。
4. 打开后按窗口里的引导允许麦克风等权限即可。

这个版本没有经过 Apple 公证，所以需要手动放行。应用在本机识别语音，不会上传音频。
系统要求：macOS 14 或更新；使用 Whisper 高精度识别建议 Apple 芯片的 Mac。
TXT
fi

rm -f "$DMG"
hdiutil create -volname "LiveCaption $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "✓ 安装包：$DMG（$(du -h "$DMG" | cut -f1 | tr -d ' ')）"

if [[ "$SIGN_IDENTITY" == Developer\ ID* ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "→ 提交公证（通常要几分钟）…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "✓ 已公证，可以直接分发"
  else
    echo "  还没有公证：设置 NOTARY_PROFILE 后重新运行，对方才能双击直接打开"
  fi
else
  echo "  临时签名版本：对方第一次打开需要按「首次打开说明.txt」手动放行"
fi
