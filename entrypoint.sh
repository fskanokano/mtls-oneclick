#!/usr/bin/env bash
# entrypoint.sh — 容器入口：启动 nginx + fail2ban

set -e

echo "[entrypoint] starting mTLS nginx..."

# 确保目录存在
mkdir -p /var/log/nginx
mkdir -p /var/log/nginx/ban
mkdir -p /var/lib/fail2ban

# 启动 fail2ban（后台）
fail2ban-server -b -f --logtarget /var/log/fail2ban.log

# 等待 fail2ban 就绪
sleep 2

# 加载 jail
for jail in nginx-mtls nginx-ratelimit; do
    fail2ban-client add "$jail" 2>/dev/null || true
    fail2ban-client start "$jail" 2>/dev/null || true
done

echo "[entrypoint] fail2ban started"

# 启动 nginx（前台）
exec nginx -g 'daemon off;'