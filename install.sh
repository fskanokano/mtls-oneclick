#!/usr/bin/env bash
# ============================================================
# install.sh — 一键部署 mTLS 加固 nginx（ARM64 Oracle VPS）
#
# 用法: bash install.sh <EXPOSE_PORT> <PROXY_PORT>
#
# 示例:
#   bash install.sh 8443 8080     # 暴露 8443，代理到本地 8080
#   bash install.sh 443 3000       # 标准 HTTPS 端口，代理到 3000
# ============================================================

set -euo pipefail

# ── 参数 ──
EXPOSE_PORT="${1:?用法: bash install.sh <EXPOSE_PORT> <PROXY_PORT>}"
PROXY_PORT="${2:?用法: bash install.sh <EXPOSE_PORT> <PROXY_PORT>}"

# 宿主机用户身份（非特权镜像以此 uid 运行容器，才能读取 chmod 600 的私钥）
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

# ── 路径 ──
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
CERTS_DIR="${INSTALL_DIR}/certs"
SERVERS_DIR="${CERTS_DIR}/servers/${EXPOSE_PORT}"
CONF_DIR="${INSTALL_DIR}/nginx/conf.d"
CLIENTS_DIR="${CERTS_DIR}/clients"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[-]${NC} $*"; exit 1; }
info() { echo -e "${CYAN}[*]${NC} $*"; }

# ── 依赖检查 ──
for cmd in docker openssl; do
    command -v "$cmd" &>/dev/null || err "缺少依赖: $cmd (apt install docker.io openssl)"
done

# Docker Compose v1 或 v2 兼容
if docker compose version &>/dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &>/dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    DOCKER_COMPOSE="docker compose"
fi

# ── 端口检查 ──
# 非特权镜像以普通用户运行，无法绑定 <1024 的特权端口
if [ "${EXPOSE_PORT}" -lt 1024 ]; then
    err "非特权镜像要求 EXPOSE_PORT >= 1024（当前: ${EXPOSE_PORT}），请更换端口"
fi
if ss -tlnp 2>/dev/null | grep -q ":${EXPOSE_PORT} "; then
    warn "端口 ${EXPOSE_PORT} 已被占用，请先释放或选择其他端口"
    ss -tlnp | grep ":${EXPOSE_PORT} "
    exit 1
fi

echo ""
echo "============================================================"
echo "  mTLS 一键加固部署"
echo "  暴露端口: ${EXPOSE_PORT}  →  代理端口: ${PROXY_PORT}"
echo "============================================================"
echo ""

# ================================================================
# 阶段 1: 初始化 CA（如果不存在）
# ================================================================
CA_KEY="${CERTS_DIR}/ca.key"
CA_CRT="${CERTS_DIR}/ca.crt"

if [ ! -f "${CA_KEY}" ] || [ ! -f "${CA_CRT}" ]; then
    log "未检测到 CA，正在生成…"
    mkdir -p "${CERTS_DIR}" "${CLIENTS_DIR}"

    openssl ecparam -genkey -name secp384r1 -out "${CA_KEY}"
    chmod 600 "${CA_KEY}"

    openssl req -new -x509 -days 3650 -key "${CA_KEY}" -out "${CA_CRT}" \
      -subj "/C=CN/O=MTLS-Proxy/CN=MTLS Root CA"

    # 初始化吊销数据库
    touch "${CERTS_DIR}/index.txt"
    echo "01" > "${CERTS_DIR}/serial"

    # 生成空 CRL
    openssl ca -gencrl -keyfile "${CA_KEY}" -cert "${CA_CRT}" \
      -out "${CERTS_DIR}/ca.crl" -crldays 30 \
      -config <(printf "[ ca ]\ndefault_ca = CA_default\n[ CA_default ]\ndatabase = %s/index.txt\ndefault_crl_days = 30\ndefault_md = sha256\n" "${CERTS_DIR}")

    log "CA 初始化完成: ${CA_CRT}"
else
    info "CA 已存在，跳过初始化"
fi

# ================================================================
# 阶段 2: 生成该端口的服务器证书
# ================================================================
if [ -f "${SERVERS_DIR}/server.crt" ]; then
    warn "端口 ${EXPOSE_PORT} 已有服务器证书，跳过生成"
else
    log "为端口 ${EXPOSE_PORT} 生成服务器证书…"
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
    log "服务器证书生成完成"
fi

# ================================================================
# 阶段 3: 生成 nginx 站点配置
# ================================================================
CONF_FILE="${CONF_DIR}/site-${EXPOSE_PORT}.conf"
log "生成 nginx 配置: ${CONF_FILE}"

sed \
  -e "s/__EXPOSE_PORT__/${EXPOSE_PORT}/g" \
  -e "s/__PROXY_PORT__/${PROXY_PORT}/g" \
  "${INSTALL_DIR}/nginx/site.template.conf" > "${CONF_FILE}"

# ================================================================
# 阶段 4: 构建 Docker 镜像 + 启动
# ================================================================

# 生成 docker-compose.yml（非特权镜像，无 privileged/cap_add）
cat > "${INSTALL_DIR}/docker-compose.yml" << YML
services:
  nginx-mtls:
    build: .
    image: nginx-mtls:latest
    container_name: nginx-mtls
    network_mode: host
    restart: unless-stopped
    user: "${HOST_UID}:${HOST_GID}"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./certs:/etc/nginx/certs:ro
      - ./www/install:/var/www/install:ro
YML

# ── 强制清理，防止复用旧的/被污染的镜像与构建缓存 ──
# 历史问题: 容器曾因复用 stale 旧镜像(COPY entrypoint.sh 层 / 留影 project image)
# 而跑旧代码。这里强删容器+镜像，再用 compose --build --no-cache 彻底重建。
log "强制清理旧镜像与容器…"
docker rm -f nginx-mtls 2>/dev/null || true
docker rmi -f nginx-mtls:latest 2>/dev/null || true

log "构建 Docker 镜像…"
# 用 compose build --no-cache，镜像一定打到 image: nginx-mtls:latest，
# 避免 docker build 独立打标签与 compose 留影镜像不一致。
${DOCKER_COMPOSE} -f "${INSTALL_DIR}/docker-compose.yml" build --no-cache

# 停止旧容器（如果存在）
docker stop nginx-mtls 2>/dev/null || true
docker rm nginx-mtls 2>/dev/null || true

log "启动容器…"
${DOCKER_COMPOSE} -f "${INSTALL_DIR}/docker-compose.yml" up -d

# ── 验证（轮询等待 nginx 就绪，最多 30 秒）──
# 非特权镜像 nginx 自身启动极快，轮询而非一次性检查，避免启动瞬间误报
HEALTH_OK=0
for i in $(seq 1 30); do
    if curl -sk "https://127.0.0.1:${EXPOSE_PORT}/nginx-health" 2>/dev/null | grep -q ok; then
        HEALTH_OK=1
        break
    fi
    sleep 1
done

if [ "${HEALTH_OK}" = "1" ]; then
    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}✅ 部署成功！${NC}"
    echo "============================================================"
    echo ""
    echo "  访问地址:   https://<你的服务器IP>:${EXPOSE_PORT}"
    echo "  安装引导:   https://<你的服务器IP>:${EXPOSE_PORT}/install/"
    echo "  健康检查:   https://<你的服务器IP>:${EXPOSE_PORT}/nginx-health"
    echo ""
    echo "  管理命令:"
    echo "    生成客户端证书: bash ${INSTALL_DIR}/scripts/gen-client.sh <用户名> [密码]"
    echo "    吊销客户端证书: bash ${INSTALL_DIR}/scripts/revoke-client.sh <用户名>"
    echo "    增加新端口:     bash ${INSTALL_DIR}/add-port.sh <端口> <代理端口>"
    echo "    查看日志:       ${DOCKER_COMPOSE} -f ${INSTALL_DIR}/docker-compose.yml logs -f"
    echo ""
else
    warn "健康检查失败（等待 ${EXPOSE_PORT} 端口 30 秒仍未就绪），最近日志:"
    echo ""
    ${DOCKER_COMPOSE} -f "${INSTALL_DIR}/docker-compose.yml" logs --tail=30
fi