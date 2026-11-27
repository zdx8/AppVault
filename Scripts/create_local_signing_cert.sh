#!/usr/bin/env bash
# 生成本机自签代码签名证书「AppVault Local Sign」，供 package_app.sh 自动选用。
# 不能用于 Apple 公证；仅本机 / 手动信任的机器可用。
set -euo pipefail

CERT_NAME="AppVault Local Sign"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
DAYS="${CERT_DAYS:-3650}"

if ! command -v openssl >/dev/null 2>&1; then
  echo "需要 openssl。" >&2
  exit 1
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -F "\"${CERT_NAME}\"" >/dev/null; then
  echo "已存在可用身份：${CERT_NAME}"
  security find-identity -v -p codesigning | grep -F "${CERT_NAME}" || true
  exit 0
fi

TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/appvault-codesign.XXXXXX")"
cleanup() { rm -rf "${TMPDIR}"; }
trap cleanup EXIT

CONF="${TMPDIR}/openssl.cnf"
KEY="${TMPDIR}/key.pem"
CRT="${TMPDIR}/cert.pem"
P12="${TMPDIR}/cert.p12"

cat > "${CONF}" <<'EOF'
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = codesign_ext

[ dn ]
CN = AppVault Local Sign
OU = AppVault
O  = AppVault Local
C  = CN

[ codesign_ext ]
basicConstraints       = critical,CA:FALSE
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
EOF

echo "[1/4] 生成自签代码签名证书（有效期 ${DAYS} 天）..."
openssl req -new -x509 -days "${DAYS}" -nodes \
  -config "${CONF}" \
  -keyout "${KEY}" \
  -out "${CRT}" >/dev/null

# 临时口令仅用于 PKCS#12 中转；导入后随 TMPDIR 删除。
# macOS security 不吃 OpenSSL 3 默认算法，需兼容的 SHA1/3DES 或 -legacy。
P12_PASS="appvault-local-$(openssl rand -hex 8)"
if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
  openssl pkcs12 -export -legacy \
    -inkey "${KEY}" \
    -in "${CRT}" \
    -out "${P12}" \
    -passout "pass:${P12_PASS}" \
    -name "${CERT_NAME}" >/dev/null
else
  openssl pkcs12 -export \
    -inkey "${KEY}" \
    -in "${CRT}" \
    -out "${P12}" \
    -passout "pass:${P12_PASS}" \
    -name "${CERT_NAME}" \
    -certpbe PBE-SHA1-3DES \
    -keypbe PBE-SHA1-3DES \
    -macalg sha1 >/dev/null
fi

echo "[2/4] 导入登录钥匙串（允许 codesign 访问私钥）..."
if [[ ! -f "${KEYCHAIN}" ]]; then
  KEYCHAIN="${HOME}/Library/Keychains/login.keychain"
fi

security import "${P12}" \
  -k "${KEYCHAIN}" \
  -P "${P12_PASS}" \
  -A \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  -T /usr/bin/productsign >/dev/null

unset P12_PASS

echo "[3/4] 将证书信任为代码签名..."
# 用户级 trustRoot + codeSign，codesign 才会列出 valid identity
if ! security add-trusted-cert -d -r trustRoot -p codeSign "${CRT}" 2>/dev/null; then
  echo "自动设置信任失败。请打开「钥匙串访问」→「我的证书」→「${CERT_NAME}」" >&2
  echo "→ 显示介绍 → 信任 → 代码签名 = 始终信任，然后关闭窗口。" >&2
fi

# 尽量让 codesign 免弹窗取钥（无钥匙串密码时才成功；失败可忽略）
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -l "${CERT_NAME}" \
  "${KEYCHAIN}" >/dev/null 2>&1 || true

echo "[4/4] 校验身份..."
if security find-identity -v -p codesigning 2>/dev/null | grep -F "${CERT_NAME}" >/dev/null; then
  security find-identity -v -p codesigning | grep -F "${CERT_NAME}" || true
  echo
  echo "完成。接下来执行："
  echo "  ./Scripts/package_app.sh"
  echo "脚本会自动用「${CERT_NAME}」签名（也可 CODESIGN_IDENTITY=\"${CERT_NAME}\"）。"
else
  echo "证书已导入，但尚未出现在 codesigning identities 中。" >&2
  echo "请到钥匙串访问手动将「${CERT_NAME}」的「代码签名」设为「始终信任」，关闭窗口后再跑：" >&2
  echo "  security find-identity -v -p codesigning" >&2
  exit 1
fi
