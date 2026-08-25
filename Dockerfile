FROM nginx:1.27-alpine

# 安装必要工具
RUN apk add --no-cache \
    openssl \
    fail2ban \
    iptables \
    bash \
    grep \
    sed \
    curl

# fail2ban 目录
RUN mkdir -p /var/run/fail2ban

# 复制 nginx 主配置
COPY nginx/nginx.conf /etc/nginx/nginx.conf

# 复制静态页面
COPY www/install/index.html /var/www/install/index.html
COPY www/protected/index.html /var/www/protected/index.html

# 复制 fail2ban 配置
COPY iptables/jail.local /etc/fail2ban/jail.local
COPY iptables/nginx-mtls.conf /etc/fail2ban/filter.d/nginx-mtls.conf
COPY iptables/nginx-ratelimit.conf /etc/fail2ban/filter.d/nginx-ratelimit.conf

# 复制脚本
COPY scripts/ /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

# 入口脚本
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]