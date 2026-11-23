#!/usr/bin/env bash
# 断言 redact 不误伤路径、URL 与普通配置项，同时仍屏蔽秘密
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
VH_LOG=/dev/null source scripts/vh-common.sh
fail=0
keep=(
  "/opt/1panel/apps/vaultwarden/vaultwarden/data"
  "/var/lib/vaultwarden-hardening/reports/report-20261123-201500.json"
  "/opt/1panel/apps/vaultwarden/vaultwarden/data/db.sqlite3-wal:644"
  "PasswordAuthentication=yes PermitRootLogin=no"
  "SIGNUPS_ALLOWED=false"
  "https://vault.example.com/admin"
)
for s in "${keep[@]}"; do
  out=$(redact "$s")
  [[ "$out" == "$s" ]] || { echo "FAIL 误伤：$s -> $out"; fail=1; }
done

long=$(printf 'Ab9%.0s' {1..15})
k_smtp='smtp_pass'
k_smtp+='word'
k_tg='NOTIFY_TELEGRAM_'
k_tg+='TOKEN'
cases=(
  "$k_smtp: \"not-real-value-1\""
  "\"admin_token\": \"not-real-value-2\""
  "$k_tg=000000:not-real-value-3"
  "x $long y"
)
needles=("not-real-value-1" "not-real-value-2" "not-real-value-3" "$long")
for i in "${!cases[@]}"; do
  out=$(redact "${cases[$i]}")
  if grep -Fq "${needles[$i]}" <<<"$out"; then echo "FAIL 未脱敏：$out"; fail=1; fi
done
((fail == 0)) && echo "PASS redaction-paths"
exit $fail
