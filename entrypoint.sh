#!/usr/bin/env bash
# entrypoint.sh — 容器入口：启动 nginx（前台）+ fail2ban（后台）
#
# 设计原则: nginx 是核心服务必须立即启动(PID 1)；
#           fail2ban 只是加固辅助，绝不能阻塞 nginx。

set -e

echo "[entrypoint] starting mTLS nginx..."

# 确保目录存在
mkdir -p /var/log/nginx
mkdir -p /var/log/nginx/ban
mkdir -p /var/lib/fail2ban
mkdir -p /var/run/fail2ban

# 预创建日志文件，避免 fail2ban 因日志文件不存在而启动失败
touch /var/log/nginx/error.log /var/log/nginx/access.log /var/log/fail2ban.log
# 兜底：即使有系统默认 ssh jail 未被禁用，也不会因缺少日志文件而失败
touch /var/log/auth.log

# ── fail2ban: 完全后台化，独立子 shell，绝不阻塞 nginx ──
(
    # 启动 fail2ban 服务；-k 3 确保即使进程忽略 SIGTERM 也会被强杀，
    # 否则 timeout 只发 TERM 后会无限等待，把整个入口脚本挂死
    if ! timeout -k 3 15 fail2ban-server -b --logtarget /var/log/fail2ban.log; then
        echo "[entrypoint] WARN: fail2ban 启动失败/超时，仅启动 nginx"
        exit 0
    fi

    sleep 2

    # 加载 jail（限时 + 强杀兜底，防止 client 卡死）
    for jail in nginx-mtls nginx-ratelimit; do
        timeout -k 3 5 fail2ban-client add "$jail" >/dev/null 2>&1 || true
        timeout -k 3 5 fail2ban-client start "$jail" >/dev/null 2>&1 || true
    done

    echo "[entrypoint] fail2ban jails started"
) &
disown

echo "[entrypoint] fail2ban launched in background"

# ── 启动 nginx（前台，作为 PID 1）──
exec nginx -g 'daemon off;'