# mTLS nginx 一键加固

> 专为 Oracle ARM VPS 打造 · host 网络模式 · 自动证书管理 · 暴力测试自动拉黑

## 效果

```
浏览器 ──→ https://你的VPS:端口
              │
              ├─ 无证书  → 302 → /install/ 引导页（下载 .p12 + 分平台教程）
              │
              ├─ 有效证书 → ✅ 代理到 127.0.0.1:后端端口
              │
              ├─ 证书被吊销 → 🚫 403（CRL 实时生效）
              │
              └─ 暴力攻击 → 🚫 IP 被 fail2ban + iptables 自动拉黑
```

## 快速开始

```bash
# 1. 克隆
git clone https://github.com/YOUR_USERNAME/mtls-oneclick.git
cd mtls-oneclick

# 2. 一键部署（暴露端口 8443，代理到本地 3000）
bash install.sh 8443 3000

# 3. 生成第一个客户端证书
bash scripts/gen-client.sh alice
```

浏览器访问 `https://<VPS_IP>:8443` → 自动跳转安装引导页 → 下载 `alice.p12` → 按教程导入 → 刷新即可访问。

## 命令速查

| 操作 | 命令 |
|------|------|
| **首次部署** | `bash install.sh <暴露端口> <代理端口>` |
| **新增端口** | `bash add-port.sh <暴露端口> <代理端口>` |
| **生成客户端证书** | `bash scripts/gen-client.sh <用户名> [密码]` |
| **吊销客户端证书** | `bash scripts/revoke-client.sh <用户名>` |
| **查看运行状态** | `bash scripts/status.sh` |
| **解封 IP** | `bash scripts/unban.sh <IP>` |
| **查看日志** | `docker compose logs -f` |
| **重载配置** | `docker exec nginx-mtls nginx -s reload` |

## 架构

```
/opt/mtls-oneclick/
├── install.sh                  # 一键部署
├── add-port.sh                 # 新增端口（热加载，不影响已有端口）
├── Dockerfile                  # nginxinc/nginx-unprivileged（非 root，暂未加 fail2ban）
├── docker-compose.yml          # host 网络模式（自动生成）
├── nginx/
│   ├── nginx.conf              # 主配置（rate limiting zones）
│   ├── site.template.conf      # 站点配置模板（不挂载入容器 conf.d，避免被解析）
│   └── conf.d/
│       └── site-8443.conf      # 每个端口一个配置（自动生成）
├── certs/
│   ├── ca.key / ca.crt / ca.crl    # CA 证书体系
│   ├── servers/<port>/             # 每个端口的服务器证书
│   └── clients/<username>/         # 客户端证书 + .p12
├── www/
│   ├── install/index.html          # 安装引导页（免证书 + 限速保护）
│   └── protected/index.html        # 受保护站点默认页
├── scripts/
│   ├── gen-client.sh               # 生成客户端证书
│   ├── revoke-client.sh            # 吊销客户端证书
│   ├── status.sh                   # 查看状态
│   └── unban.sh                    # 解封 IP
└── iptables/
    ├── jail.local                  # fail2ban jail 配置
    ├── nginx-mtls.conf             # mTLS 暴力尝试过滤器
    └── nginx-ratelimit.conf        # 限速触发过滤器
```

## 安全防护层（v0.x 核心版：暂无 fail2ban，后续再扩展）

| 层级 | 机制 | 说明 |
|------|------|------|
| **L1 限速** | nginx `limit_req` | /install/ 单 IP 10次/分钟，burst 3 |
| **L2 限速** | nginx `limit_conn` | 单 IP 最多 20 并发连接 |
| **L3 审计**  | nginx access/error log | TLS 校验失败/429/444 写入日志，供 fail2ban/Loki 采集 |
| **L4 证书管控** | mTLS + CRL | 客户端证书校验失败 → 直接拒连；吊销证书即时生效 |

## 浏览器兼容

安装引导页内置浏览器/OS 自动检测，对 Chrome / Firefox / Safari / Edge × Windows / macOS / Linux / iOS / Android 每种组合提供独立教程。

## 前置要求

- Oracle ARM VPS（或其他 ARM64 Linux）
- Docker + Docker Compose
- OpenSSL（宿主机）
- 防火墙开放目标端口

```bash
# Ubuntu/Debian 安装依赖
sudo apt update && sudo apt install -y docker.io openssl
sudo systemctl enable --now docker
```

## 注意事项

1. **CA 私钥** (`certs/ca.key`) 是整个体系的根，**务必备份**，泄露/丢失则全部作废
2. fail2ban 需要 `privileged: true` + `NET_ADMIN` 才能操作 iptables
3. host 网络模式下容器直接监听宿主机端口，无需端口映射
4. 容器重启后 fail2ban 封禁列表会丢失（可用 `fail2ban-persistent` 持久化）
5. 吊销证书后 CRL 在 TLS 握手时实时读取，**无需重启 nginx**