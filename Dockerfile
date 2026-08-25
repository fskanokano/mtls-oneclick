# ============================================================
# mTLS 核心 nginx — 基于官方非特权镜像（无 root、无 fail2ban）
# 仅保留核心 mTLS 反代能力，后续再扩展加固组件
# ============================================================
FROM nginxinc/nginx-unprivileged:1.31-trixie-perl

# nginx 主配置（pid 与临时目录已指向 /tmp，适配非 root 运行）
COPY nginx/nginx.conf /etc/nginx/nginx.conf

# 静态页面
COPY www/install/index.html /usr/share/nginx/html/install/index.html
COPY www/protected/index.html /usr/share/nginx/html/protected/index.html

# 使用镜像自带的 docker-entrypoint.sh + nginx 前台默认 CMD