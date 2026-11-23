#!/usr/bin/env bash
# 用桩命令模拟 docker 环境，断言审计不修改数据目录
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/data" "$T/state"
echo '{"signups_allowed":false}' >"$T/data/config.json"
chmod 640 "$T/data/config.json"
cat >"$T/bin/docker" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "ps -a --format"*) echo abc ;;
  *"Destination"*) echo "$T/data" ;;
  *".Config.Image"*) echo vaultwarden/server:1.32.5 ;;
  *".Name"*) echo /vaultwarden ;;
  *) echo "" ;;
esac
EOF
chmod +x "$T/bin/docker"
before=$(cd "$T/data" && find . -printf '%p %T@ %m\n' | sort)
PATH="$T/bin:$PATH" VH_CONF=/nonexistent VBM_CONF=/nonexistent VH_STATE="$T/state" VH_LOG=/dev/null VH_LOCK="$T/lock" \
  bash scripts/vh-audit.sh --domain app >/dev/null 2>&1 || true
after=$(cd "$T/data" && find . -printf '%p %T@ %m\n' | sort)
[[ "$before" == "$after" ]] || { echo "FAIL 数据目录被修改"; exit 1; }
ls "$T/state/reports"/report-*.json >/dev/null 2>&1 || { echo "FAIL 未生成报告"; exit 1; }
echo "PASS audit-readonly"
