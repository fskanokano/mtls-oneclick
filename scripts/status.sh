#!/usr/bin/env bash
# status.sh — 查看 mTLS nginx 运行状态

set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CERTS_DIR="${INSTALL_DIR}/certs"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo ""
echo "============================================================"
echo "  mTLS Nginx 运行状态"
echo "============================================================"
echo ""

# 容器状态
if docker ps --format '{{.Names}}' | grep -q 'nginx-mtls'; then
    echo -e "${GREEN}●${NC} 容器: nginx-mtls (运行中)"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  活跃端口:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    for conf in "${INSTALL_DIR}/nginx/conf.d/site-"*.conf; do
        [ -f "$conf" ] || continue
        port=$(grep -oP 'listen \K\d+' "$conf" | head -1)
        proxy=$(grep -oP 'proxy_pass http://127.0.0.1:\K\d+' "$conf" | head -1)
        health=$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1:${port}/nginx-health" 2>/dev/null || echo "DOWN")
        if [ "$health" = "200" ]; then
            status="${GREEN}✓${NC}"
        else
            status="${RED}✗${NC}"
        fi
        printf "  %b  :%-5s → 127.0.0.1:%-5s  %s\n" "$status" "$port" "$proxy" "$health"
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  客户端证书:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    CLIENTS_COUNT=0
    for dir in "${CERTS_DIR}/clients/"*/; do
        [ -d "$dir" ] || continue
        user=$(basename "$dir")
        crt="${dir}/client.crt"
        if [ -f "$crt" ]; then
            expiry=$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2)
            revoked=""
            if grep -q "${user}" "${CERTS_DIR}/index.txt" 2>/dev/null; then
                if grep -q "R.*${user}" "${CERTS_DIR}/index.txt" 2>/dev/null; then
                    revoked=" ${RED}[已吊销]${NC}"
                fi
            fi
            printf "  ${CYAN}👤${NC} %-15s  过期: %s%b\n" "$user" "$expiry" "$revoked"
            CLIENTS_COUNT=$((CLIENTS_COUNT + 1))
        fi
    done

    if [ "$CLIENTS_COUNT" -eq 0 ]; then
        echo "  (无客户端证书)"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  封禁 IP (fail2ban):"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # 检查 iptables
    BANNED=0
    for chain in f2b-nginx-mtls f2b-nginx-ratelimit; do
        if sudo iptables -L "$chain" -n 2>/dev/null | grep -q 'DROP\|REJECT'; then
            echo "  [${chain}]"
            sudo iptables -L "$chain" -n 2>/dev/null | grep 'DROP\|REJECT' | while read -r line; do
                ip=$(echo "$line" | awk '{print $4}')
                echo "    🚫 ${ip}"
            done
            BANNED=1
        fi
    done

    if [ "$BANNED" -eq 0 ]; then
        echo "  (无封禁 IP)"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  最近限速/暴力攻击日志 (5 条):"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    docker exec nginx-mtls grep -E '429|ban|limit' /var/log/nginx/error.log 2>/dev/null | tail -5 || echo "  (无)"
    echo ""

else
    echo -e "${RED}✗${NC} 容器未运行"
fi