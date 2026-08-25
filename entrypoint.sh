#!/usr/bin/env bash
# entrypoint.sh — 容器入口：启动 nginx + fail2ban

set -e

echo "[entrypoint] starting mTLS nginx..."

# 确保目录存在
mkdir -p /var/log/nginx
mkdir -p /var/log/nginx/ban
mkdir -p /var/lib/fail2ban

# 预创建日志文件，避免 fail2ban 因日志文件不存在而启动失败
touch /var/log/nginx/error.log /var/log/nginx/access.log /var/log/fail2ban.log
# 兜底：即使有系统默认 ssh jail 未被禁用，也不会因缺少日志文件而失败
touch /var/log/auth.log

# 启动 fail2ban（后台）
# 加超时兜底：fail2ban 异常卡死时不能阻塞 nginx 启动
if ! timeout 15 fail2ban-server -b --logtarget /var/log/fail2ban.log; then
    echo "[entrypoint] WARN: fail2ban start timeout/failed, starting nginx only"
fi

# 等待 fail2ban 就绪
sleep 2

# 加载 jail（限时，防止 client 卡死阻塞 nginx）
for jail in nginx-mtls nginx-ratelimit; do
    timeout 5 fail2ban-client add "$jail" >/dev/null 2>&1 || true
    timeout 5 fail2ban-client start "$jail" >/dev/null 2>&1 || true
done

echo "[entrypoint] fail2ban started"

# 启动 nginx（前台）
exec nginx -g 'daemon off;'