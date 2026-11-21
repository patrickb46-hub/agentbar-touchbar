#!/bin/bash
# 建一张固定的自签名代码签名证书，只给这台机器上的 AgentBar 用。
#
# 为什么要它：TCC（辅助功能授权）是按「指定要求」记账的。
#   ad-hoc 签名 → 指定要求 = 二进制的指纹，每次编译都变，授权就作废；
#   自签证书     → 指定要求 = bundle id + 证书根，重装也不用重新授权。
#
# 幂等：已经有同名身份就直接退出。
set -euo pipefail

NAME="AgentBar Self Signed"
DIR="$HOME/.agentbar/signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
PASS="agentbar"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "已经有「${NAME}」这个签名身份，跳过。"
    exit 0
fi

mkdir -p "$DIR"
cd "$DIR"

cat > openssl.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = AgentBar Self Signed
O = String255 Local
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

echo "生成证书（10 年有效）…"
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
    -days 3650 -nodes -config openssl.cnf 2>/dev/null
openssl pkcs12 -export -inkey key.pem -in cert.pem -out identity.p12 \
    -passout "pass:$PASS" -name "$NAME"

echo "导入登录钥匙串（-A：允许 codesign 直接取用，不再弹窗）…"
security import identity.p12 -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign -A

# 必须再把它标成可信，否则系统认为签名无效 —— TCC 会退回按二进制指纹记账，
# 授权又变成每次重装都要重给（踩过：只导入不信任，勾了复选框也不生效）。
# 这一步可能弹一次登录密码框。
echo "标记为可信（codeSign 策略；可能要输一次登录密码）…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" cert.pem

echo
security find-identity -v -p codesigning | grep "$NAME" || {
    echo "导入失败：找不到「${NAME}」" >&2
    exit 1
}
echo
echo "好了。私钥在 $DIR/key.pem，别提交进仓库（$DIR 在 ~/.agentbar 下，不在项目里）。"
