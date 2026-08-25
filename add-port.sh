#!/usr/bin/env bash
# ============================================================
# add-port.sh — 一键增加 mTLS 加固端口（需先运行 install.sh）
#
# 用法: bash add-port.sh <EXPOSE_PORT> <PROXY_PORT>
#
# 示例:
#   bash add-port.sh 9443 9090     # 新增 9443 → 本地 9090
# ============================================================

set -euo pipefail

EXPOSE_PORT="${1:?用法: bash add-port.sh <EXPOSE_PORT> <PROXY_PORT>}"
PROXY_PORT="${2:?用法: bash add-port.sh <EXPOSE_PORT> <PROXY_PORT>}"

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
CERTS_DIR="${INSTALL_DIR}/certs"
SERVERS_DIR="${CERTS_DIR}/servers/${EXPOSE_PORT}"
CA_KEY="${CERTS_DIR}/ca.key"
CA_CRT="${CERTS_DIR}/ca.crt"
CONF_FILE="${INSTALL_DIR}/nginx/conf.d/site-${EXPOSE_PORT}.conf"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*"; exit 1; }

# ── 前置检查 ──
if [ ! -f "${CA_KEY}" ] || [ ! -f "${CA_CRT}" ]; then
    err "CA 不存在，请先运行 install.sh 初始化系统"
fi

if ! docker ps --format '{{.Names}}' | grep -q 'nginx-mtls'; then
    err "nginx-mtls 容器未运行，请先运行 install.sh"
fi

# ── 端口冲突检查 ──
# 非特权镜像无法绑定 <1024 的特权端口
if [ "${EXPOSE_PORT}" -lt 1024 ]; then
    err "非特权镜像要求 EXPOSE_PORT >= 1024（当前: ${EXPOSE_PORT}）"
fi
if ss -tlnp 2>/dev/null | grep -q ":${EXPOSE_PORT} "; then
    warn "端口 ${EXPOSE_PORT} 已被占用"
    ss -tlnp | grep ":${EXPOSE_PORT}"
    exit 1
fi

if [ -f "${CONF_FILE}" ]; then
    warn "端口 ${EXPOSE_PORT} 配置文件已存在，跳过"
    warn "如需重新生成请先: rm ${CONF_FILE} && rm -rf ${SERVERS_DIR}"
    exit 0
fi

echo ""
echo "============================================================"
echo "  新增 mTLS 加固端口"
echo "  暴露端口: ${EXPOSE_PORT}  →  代理端口: ${PROXY_PORT}"
echo "============================================================"
echo ""

# ================================================================
# 1. 生成服务器证书
# ================================================================
log "生成服务器证书…"
mkdir -p "${SERVERS_DIR}"

openssl ecparam -genkey -name secp384r1 -out "${SERVERS_DIR}/server.key"
chmod 600 "${SERVERS_DIR}/server.key"

openssl req -new -key "${SERVERS_DIR}/server.key" \
  -out "${SERVERS_DIR}/server.csr" \
  -subj "/C=CN/O=MTLS-Proxy/CN=port-${EXPOSE_PORT}"

openssl x509 -req -days 365 \
  -in "${SERVERS_DIR}/server.csr" \
  -CA "${CA_CRT}" -CAkey "${CA_KEY}" -CAcreateserial \
  -out "${SERVERS_DIR}/server.crt" -sha256 \
  -extfile <(printf "keyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n")

rm -f "${SERVERS_DIR}/server.csr"
log "服务器证书已生成"

# ================================================================
# 2. 生成 nginx 配置
# ================================================================
log "生成 nginx 配置…"
sed \
  -e "s/__EXPOSE_PORT__/${EXPOSE_PORT}/g" \
  -e "s/__PROXY_PORT__/${PROXY_PORT}/g" \
  "${INSTALL_DIR}/nginx/conf.d/site.template.conf" > "${CONF_FILE}"

# ================================================================
# 3. 重载 nginx（热加载，不影响其他端口）
# ================================================================
log "重载 nginx…"
docker exec nginx-mtls nginx -t
docker exec nginx-mtls nginx -s reload

sleep 1

# ── 验证 ──
if curl -sk "https://127.0.0.1:${EXPOSE_PORT}/nginx-health" 2>/dev/null | grep -q ok; then
    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}✅ 端口 ${EXPOSE_PORT} 已上线${NC}"
    echo "============================================================"
    echo ""
    echo "  访问: https://<IP>:${EXPOSE_PORT}"
else
    warn "健康检查失败，请检查 nginx 错误日志:"
    echo "  docker exec nginx-mtls cat /var/log/nginx/error.log | tail -20"
fi

# ── 更新 docker-compose 挂载（端口配置已通过 conf.d 目录挂载自动生效） ──
log "配置文件已挂载，下次容器重启也会自动加载"