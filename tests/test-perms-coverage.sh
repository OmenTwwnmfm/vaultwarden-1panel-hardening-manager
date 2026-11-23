#!/usr/bin/env bash
# 断言 D-02 覆盖 -wal/-shm/rsa_key*/attachments/sends，且 plan --diff 给出对应差异
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib.sh
source tests/lib.sh
mk_env
trap 'rm -rf "$T"' EXIT
D="$T/data"
mkdir -p "$D/attachments" "$D/sends"
for f in db.sqlite3 db.sqlite3-wal db.sqlite3-shm rsa_key.pem rsa_key.pub.pem config.json; do
  : >"$D/$f"
  chmod 600 "$D/$f"
done
chmod 700 "$D" "$D/sends"
chmod 755 "$D/attachments"
chmod 644 "$D/db.sqlite3-wal"
fail=0

VW_DATA_DIR=$D source scripts/vh-common.sh
list=$(VW_DATA_DIR=$D vw_sensitive_paths)
for n in db.sqlite3-wal db.sqlite3-shm rsa_key.pem rsa_key.pub.pem attachments sends; do
  grep -qxF "$D/$n" <<<"$list" || { echo "FAIL 列表缺少 $n"; fail=1; }
done

run_audit data
[[ $(field D-02) == fail ]] || { echo "FAIL D-02 应为 fail"; fail=1; }
ev=$(field D-02 evidence)
for n in "db.sqlite3-wal:644" "attachments:755"; do
  grep -qF "$n" <<<"$ev" || { echo "FAIL 证据缺少 $n：$ev"; fail=1; }
done

diff_out=$(bash scripts/vh-plan.sh --diff 2>/dev/null)
grep -qF "db.sqlite3-wal: 644 -> 640" <<<"$diff_out" || { echo "FAIL plan --diff 缺少 -wal"; fail=1; }
grep -qF "attachments: 755 -> 750" <<<"$diff_out" || { echo "FAIL plan --diff 缺少 attachments"; fail=1; }
((fail == 0)) && echo "PASS perms-coverage"
exit $fail
