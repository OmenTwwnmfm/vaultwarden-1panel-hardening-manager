#!/usr/bin/env bash
# 断言：通知时 token/含 token 的 URL 不出现在 curl 命令行，而经标准输入传入
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib.sh
source tests/lib.sh
mk_env
trap 'rm -rf "$T"' EXIT
# 明显是假值的测试串，拼接生成以免被秘密扫描误报
secret='fake-'
secret+='notify-value-0123456789'
printf 'NOTIFY_TELEGRAM_TOKEN="%s"\nNOTIFY_TELEGRAM_CHAT="1"\nNOTIFY_NTFY_URL="https://ntfy.example.com/t-%s"\n' \
  "$secret" "$secret" >>"$VH_CONF"
stub curl "printf '%s\n' \"\$*\" >>'$T/argv'; cat >>'$T/stdin'"
PATH="$T/bin:$PATH" bash scripts/vh-watch.sh notify-test >/dev/null 2>&1 || true
fail=0
[[ -s "$T/argv" ]] || { echo "FAIL curl 未被调用"; fail=1; }
[[ $(wc -l <"$T/argv") -eq 2 ]] || { echo "FAIL 应调用 2 次 curl"; fail=1; }
grep -Fq "$secret" "$T/argv" && { echo "FAIL 秘密出现在命令行"; fail=1; }
grep -Fq "$secret" "$T/stdin" || { echo "FAIL URL 未经 stdin 传入"; fail=1; }
((fail == 0)) && echo "PASS notify-no-argv"
exit $fail
