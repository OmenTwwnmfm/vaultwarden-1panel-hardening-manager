#!/usr/bin/env bash
# 基于最新审计报告生成加固计划；owner=1panel 只给面板操作指引
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"

show_diff=0
[[ "${1:-}" == --diff ]] && show_diff=1
latest="$VH_STATE/reports/latest.json"
[[ -r "$latest" ]] || die "没有审计报告，请先运行 [03] 全量审计"
plan_json="$VH_STATE/plan.json" plan_txt="$VH_STATE/plan.txt"

python3 - "$latest" "$plan_json" "$plan_txt" <<'PY'
import json, sys
rep = json.load(open(sys.argv[1], encoding="utf-8"))
GUIDE = {
  "P-01": "1Panel → 设置 → 安全：修改面板端口，并在防火墙仅放行管理 IP",
  "P-02": "1Panel → 设置 → 安全：开启安全入口，配置授权 IP/域名",
  "P-03": "1Panel → 设置 → 安全：开启两步验证 (MFA)",
  "P-04": "1Panel → 概览 → 检查更新",
  "E-01": "1Panel → 应用商店 → 已安装 → Vaultwarden → 参数：端口外部访问取消勾选（绑定 127.0.0.1）",
  "E-02": "1Panel → 网站 → 对应站点：启用 HTTPS 与强制跳转；应用参数 DOMAIN 改为 https://",
  "E-03": "1Panel → 网站 → 配置文件：为 /admin 添加 IP 白名单（见 [13] OpenResty 片段）",
  "A-01": "Vaultwarden /admin → General：关闭 Allow new signups（或应用参数 SIGNUPS_ALLOWED=false）",
  "A-02": "应用参数删除 DISABLE_ADMIN_TOKEN 或设为 false",
  "A-03": "容器内执行 vaultwarden hash 生成 argon2，替换 ADMIN_TOKEN",
  "A-04": "/admin 中关闭密码提示、按需关闭 Send/紧急访问，限制 ORG_CREATION_USERS",
  "A-05": "/admin → Icons：ICON_SERVICE=internal",
  "C-01": "移除 privileged / cap_add / docker.sock 挂载（需在 1Panel 编辑 compose，注意升级覆盖）",
  "C-02": "应用参数中将镜像固定到具体版本 tag",
  "S-01": "1Panel → 应用商店 → 已安装 → 升级（先运行 vbm 备份）",
  "N-01": "在 /etc/ssh/sshd_config.d/ 设置 PasswordAuthentication no、PermitRootLogin prohibit-password，sshd -t 后重载",
  "N-02": "启用 ufw/firewalld，仅放行 80/443 与管理 IP 的 22",
  "N-03": "apt install unattended-upgrades && dpkg-reconfigure -plow unattended-upgrades",
  "D-01": "安装 vaultwarden-1panel-backup-manager 并完成一次备份与恢复演练",
  "D-02": "自动：chmod o-rwx 数据目录及关键文件",
  "D-03": "迁移到 LUKS 加密卷（无法自动）",
}
items = []
for r in rep["results"]:
    if r["status"] not in ("fail", "warn"):
        continue
    auto = r["fix_type"] == "auto" and r["owner"] in ("vhm", "host")
    items.append({"id": r["id"], "severity": r["severity"], "owner": r["owner"],
                  "mode": "auto" if auto else r["fix_type"], "current": r["evidence"],
                  "action": GUIDE.get(r["id"], "人工处理"), "restart": False})
items.sort(key=lambda i: (i["severity"], i["id"]))
json.dump({"schema_version": 1, "source": sys.argv[1], "items": items},
          open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, indent=2)
with open(sys.argv[3], "w", encoding="utf-8") as f:
    if not items:
        f.write("计划为空：无需变更。\n")
    for i in items:
        f.write(f"[{i['severity']}] {i['id']} ({i['owner']}/{i['mode']})\n  当前：{i['current']}\n  操作：{i['action']}\n\n")
print(f"计划条目 {len(items)}，其中可自动 {sum(i['mode']=='auto' for i in items)}")
PY
chmod 600 "$plan_json" "$plan_txt"
cat "$plan_txt"

if ((show_diff)); then
  # shellcheck source=scripts/checks/_lib.sh
  source "$VH_DIR/checks/_lib.sh"
  load_instance || exit 2
  echo "---- 可自动项差异 ----"
  while IFS= read -r p; do
    m=$(stat -c '%a' "$p")
    n=$(printf '%o' $((8#$m & 8#770)))
    if [[ "$m" != "$n" ]]; then echo "chmod $p: $m -> $n"; fi
  done < <(vw_sensitive_paths)
fi
