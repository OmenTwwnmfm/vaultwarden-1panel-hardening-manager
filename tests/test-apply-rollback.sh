#!/usr/bin/env bash
# 断言：健康检查失败 → 自动回滚到原权限；成功 → 去掉其他用户权限；快照被篡改 → 拒绝回滚
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib.sh
source tests/lib.sh
mk_env
trap 'rm -rf "$T"' EXIT
D="$T/data"
for f in db.sqlite3 db.sqlite3-wal config.json; do : >"$D/$f"; done
chmod 755 "$D"
chmod 644 "$D/db.sqlite3" "$D/db.sqlite3-wal" "$D/config.json"
perms() { stat -c '%a %n' "$D" "$D"/* | sort; }
before=$(perms)
printf '{"schema_version":1,"items":[{"id":"D-02","mode":"auto"}]}\n' >"$VH_STATE/plan.json"
apply() { PATH="$T/bin:$PATH" VH_ASSUME_YES=1 VH_HEALTH_TIMEOUT=4 bash scripts/vh-apply.sh >/dev/null 2>&1; }
fail=0

# 1. 健康检查失败 → 回滚
stub docker 'case "$1" in exec) exit 1 ;; *) exit 0 ;; esac'
apply && { echo "FAIL 健康检查失败时应返回非 0"; fail=1; }
[[ "$(perms)" == "$before" ]] || { echo "FAIL 未回滚到原权限"; fail=1; }

# 2. 健康检查通过 → 其他用户权限被清除
stub docker 'exit 0'
apply || { echo "FAIL 正常应用应返回 0"; fail=1; }
while read -r m p; do
  (((8#$m & 8#007) == 0)) || { echo "FAIL $p 仍为 $m"; fail=1; }
done < <(perms)

# 3. 快照被篡改 → 拒绝回滚
snaps=("$VH_STATE"/snapshots/*/)
snap=${snaps[-1]%/}
printf '777\t0:0\t%s\n' "$D" >>"$snap/perms.tsv"
bash scripts/vh-rollback.sh --snapshot "$snap" --yes >/dev/null 2>&1 && { echo "FAIL 篡改快照仍被回滚"; fail=1; }
[[ "$(stat -c '%a' "$D")" == 750 ]] || { echo "FAIL 篡改快照改动了权限"; fail=1; }

((fail == 0)) && echo "PASS apply-rollback"
exit $fail
