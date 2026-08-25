#!/usr/bin/env bash
# unban.sh — 解封指定 IP

IP="${1:?用法: bash scripts/unban.sh <IP地址>}"

echo "解封 IP: ${IP}"

# fail2ban 解封
for jail in nginx-mtls nginx-ratelimit; do
    docker exec nginx-mtls fail2ban-client set "$jail" unbanip "$IP" 2>/dev/null && \
      echo "  ✓ fail2ban/${jail} 已解封" || \
      echo "  - fail2ban/${jail} 未命中"
done

# 手动清理 iptables（备选）
sudo iptables -D f2b-nginx-mtls -s "$IP" -j DROP 2>/dev/null || true
sudo iptables -D f2b-nginx-ratelimit -s "$IP" -j DROP 2>/dev/null || true

echo "完成"