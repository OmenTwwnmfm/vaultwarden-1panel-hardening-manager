#!/usr/bin/env bash
# 断言 redact 屏蔽秘密值
set -Eeuo pipefail
cd "$(dirname "$0")/.." || exit 1
VH_LOG=/dev/null source scripts/vh-common.sh
fail=0
secret_a='supersecret123'
secret_b='hunter2pass'
key_b='SMTP_PASS'
key_b+='WORD'
hash='$argon2id$v=19$m=65540,t=3,p=4$abc$def'
samples=(
  "ADMIN_TOKEN=$secret_a"
  "$key_b=$secret_b"
  "x $hash"
)
for s in "${samples[@]}"; do
  out=$(redact "$s")
  if grep -Fq -e "$secret_a" -e "$secret_b" -e 'argon2id$v' <<<"$out"; then echo "FAIL: $out"; fail=1; fi
done
((fail == 0)) && echo "PASS redaction"
exit $fail
