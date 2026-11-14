#!/bin/bash
# 在登录钥匙串里创建本机自签名的代码签名证书「LiveCaption Local Signing」（只需运行一次）。
# 有了它，build.sh 每次都用同一个身份签名，系统权限（麦克风 / 语音识别 / 屏幕与系统录音）
# 在重新编译后仍然有效。证书只在这台电脑上有意义，不能用来分发应用。
# 之后第一次编译时，系统可能提示「codesign 想要使用密钥」：输入登录密码并点「始终允许」。
set -euo pipefail

NAME="LiveCaption Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "✓ 证书已存在：$NAME"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > cfg <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG

# 用系统自带的 openssl（LibreSSL），生成的 .p12 才能被 security import 读取
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cfg 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"   # 只用于这一次导入的临时口令
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" -out id.p12 -passout "pass:$PASS"
security import id.p12 -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign

echo "✓ 已创建：$NAME（显示 NOT_TRUSTED 是正常的，不影响本机签名）"
echo "  删除方法：钥匙串访问 → 登录 → 我的证书 → 删除「$NAME」"
