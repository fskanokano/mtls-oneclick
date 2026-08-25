#!/usr/bin/env bash
# ============================================================
# revoke-client.sh — 吊销客户端证书 + 更新 CRL
#
# 用法: bash scripts/revoke-client.sh <用户名>
# ============================================================

set -euo pipefail

USER="${1:?用法: bash scripts/revoke-client.sh <用户名>}"

INSTALL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CERTS_DIR="${INSTALL_DIR}/certs"
CLIENT_CRT="${CERTS_DIR}/clients/${USER}/client.crt"
CA_KEY="${CERTS_DIR}/ca.key"
CA_CRT="${CERTS_DIR}/ca.crt"
CRL_FILE="${CERTS_DIR}/ca.crl"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*"; exit 1; }

[ -f "${CLIENT_CRT}" ] || err "证书不存在: ${CLIENT_CRT}"
[ -f "${CA_KEY}" ]    || err "CA 私钥不存在"

log "吊销用户 ${USER} 的证书…"

# 吊销
openssl ca -revoke "${CLIENT_CRT}" \
  -keyfile "${CA_KEY}" -cert "${CA_CRT}" \
  -config <(printf "[ ca ]\ndefault_ca = CA_default\n[ CA_default ]\ndatabase = %s/index.txt\ndefault_crl_days = 30\ndefault_md = sha256\n" "${CERTS_DIR}")

# 重新生成 CRL
openssl ca -gencrl \
  -keyfile "${CA_KEY}" -cert "${CA_CRT}" \
  -out "${CRL_FILE}" -crldays 30 \
  -config <(printf "[ ca ]\ndefault_ca = CA_default\n[ CA_default ]\ndatabase = %s/index.txt\ndefault_crl_days = 30\ndefault_md = sha256\n" "${CERTS_DIR}")

# 删除 .p12 文件（防止重新下载）
rm -f "${CERTS_DIR}/clients/${USER}/"*.p12

# 重载 nginx（CRL 在每次 TLS 握手时读取，但重载确保生效）
if docker ps --format '{{.Names}}' | grep -q 'nginx-mtls'; then
    docker exec nginx-mtls nginx -s reload
    log "nginx 已重载"
else
    log "容器未运行，CRL 将在下次启动时生效"
fi

echo ""
echo "============================================================"
echo -e "  ${GREEN}✅ 证书已吊销${NC}"
echo "============================================================"
echo ""
echo "  用户: ${USER} — 已被吊销，下次访问返回 403"
echo "  如需解封请重新签发: bash scripts/gen-client.sh ${USER}"
echo ""