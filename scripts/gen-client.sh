#!/usr/bin/env bash
# ============================================================
# gen-client.sh — 生成客户端证书（.p12 供浏览器导入）
#
# 用法:
#   bash scripts/gen-client.sh <用户名> [p12密码]
#
# 示例:
#   bash scripts/gen-client.sh alice              # 无密码
#   bash scripts/gen-client.sh bob   "mypassword"  # 有密码
# ============================================================

set -euo pipefail

USER="${1:?用法: bash scripts/gen-client.sh <用户名> [p12密码]}"
P12_PASS="${2:-}"

INSTALL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CERTS_DIR="${INSTALL_DIR}/certs"
CLIENTS_DIR="${CERTS_DIR}/clients"
USER_DIR="${CLIENTS_DIR}/${USER}"
CA_KEY="${CERTS_DIR}/ca.key"
CA_CRT="${CERTS_DIR}/ca.crt"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*"; exit 1; }

[ -f "${CA_KEY}" ] || err "CA 不存在，请先运行 install.sh"
mkdir -p "${USER_DIR}"

log "为用户 ${USER} 生成客户端证书（有效期 365 天）…"

# 1. 私钥
openssl ecparam -genkey -name secp384r1 -out "${USER_DIR}/client.key"
chmod 600 "${USER_DIR}/client.key"

# 2. CSR
openssl req -new -key "${USER_DIR}/client.key" \
  -out "${USER_DIR}/client.csr" \
  -subj "/C=CN/O=MTLS-Proxy/CN=${USER}"

# 3. 签发
openssl x509 -req -days 365 \
  -in "${USER_DIR}/client.csr" \
  -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAcreateserial \
  -out "${USER_DIR}/client.crt" -sha256 \
  -extfile <(printf "keyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n")

rm -f "${USER_DIR}/client.csr"

# 4. PKCS#12 打包
P12_FILE="${USER_DIR}/${USER}.p12"
if [ -n "${P12_PASS}" ]; then
    openssl pkcs12 -export \
      -in "${USER_DIR}/client.crt" \
      -inkey "${USER_DIR}/client.key" \
      -out "${P12_FILE}" \
      -passout "pass:${P12_PASS}" \
      -name "mTLS Client: ${USER}" \
      -certfile "${CA_CRT}"
else
    openssl pkcs12 -export \
      -in "${USER_DIR}/client.crt" \
      -inkey "${USER_DIR}/client.key" \
      -out "${P12_FILE}" \
      -passout "pass:" \
      -name "mTLS Client: ${USER}" \
      -certfile "${CA_CRT}"
fi

# 5. 也生成一个仅含证书的 .crt（可选导入）
cp "${CA_CRT}" "${USER_DIR}/ca.crt"

echo ""
echo "============================================================"
echo -e "  ${GREEN}✅ 客户端证书生成完成${NC}"
echo "============================================================"
echo ""
echo "  用户名:    ${USER}"
echo "  PKCS#12:   ${P12_FILE}"
echo "  CA 证书:   ${USER_DIR}/ca.crt"
if [ -n "${P12_PASS}" ]; then
    echo "  密码:      ${P12_PASS}"
else
    echo "  密码:      (无)"
fi
echo ""
echo "  用户访问:  https://<服务器IP>:端口"
echo "  下载安装:  https://<服务器IP>:端口/install/"
echo ""
echo "  分发方式:"
echo "    scp ${P12_FILE} user@client:~"
echo "    或放到 /install/certs/ 目录供浏览器下载（已自动挂载）"
echo ""