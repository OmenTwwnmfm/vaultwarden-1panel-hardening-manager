#!/usr/bin/env bash
# 加固指引（只打印，不修改任何东西）
set -Euo pipefail
case "${1:-}" in
  panel) cat <<'EOF'
== 1Panel 面板加固 ==
1. 设置 → 安全：修改默认面板端口；开启「安全入口」；配置「授权 IP」/「绑定域名」
2. 设置 → 安全：开启两步验证 (MFA)
3. 云厂商安全组/主机防火墙：面板端口仅放行管理 IP
4. 定期 概览 → 检查更新
EOF
  ;;
  openresty) cat <<'EOF'
== OpenResty 片段（1Panel → 网站 → 配置文件，粘贴进 server 块）==
location ^~ /admin {
    allow 203.0.113.10;   # 改为你的管理 IP
    deny  all;
    proxy_pass http://127.0.0.1:VW_PORT;   # 与现有反代一致
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
add_header Strict-Transport-Security "max-age=31536000" always;
保存后在 1Panel 中「重载」，用外部网络访问 /admin 应返回 403。
EOF
  ;;
  vaultwarden) cat <<'EOF'
== Vaultwarden 参数建议（1Panel 应用参数或 /admin，注意 config.json 优先）==
SIGNUPS_ALLOWED=false
INVITATIONS_ALLOWED=true
SHOW_PASSWORD_HINT=false
ADMIN_TOKEN=<docker exec -it <容器> /vaultwarden hash 生成的 argon2>
DOMAIN=https://vault.example.com
ICON_SERVICE=internal
ORG_CREATION_USERS=admin@example.com
修改后在 1Panel 中重建应用；先用 vbm 备份。
EOF
  ;;
  host) cat <<'EOF'
== 主机 / SSH ==
/etc/ssh/sshd_config.d/10-hardening.conf:
  PasswordAuthentication no
  PermitRootLogin prohibit-password
  KbdInteractiveAuthentication no
sshd -t && systemctl reload ssh   # 保持当前会话，另开窗口验证后再退出
ufw default deny incoming; ufw allow 80,443/tcp; ufw allow from <管理IP> to any port 22; ufw enable
apt install -y unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades
注意：Docker 发布的端口会绕过 ufw，应用端口请绑定 127.0.0.1。
EOF
  ;;
  *) echo "用法：vh-guide.sh panel|openresty|vaultwarden|host" >&2; exit 2 ;;
esac
