#!/usr/bin/env bash
# 断言 E-03 外部探测判定：2xx/3xx=fail，4xx=pass，5xx/格式无效/请求失败=unknown
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
# shellcheck source=tests/lib.sh
source tests/lib.sh
mk_env
trap 'rm -rf "$T"' EXIT
echo 'EXTERNAL_PROBE_URL="https://probe.example.com/vault-admin.txt"' >>"$VH_CONF"
stub docker 'echo ""'
stub curl 'cat >/dev/null; printf "%b" "${PROBE_BODY:-}"; exit "${PROBE_RC:-0}"'
fail=0
check() { # 响应体 退出码 期望
  export PROBE_BODY=$1 PROBE_RC=$2
  run_audit exposure
  local got
  got=$(field E-03)
  [[ $got == "$3" ]] || { echo "FAIL body='$1' rc=$2 期望 $3 实际 $got"; fail=1; }
}
check '200\n' 0 fail
check '302' 0 fail
check '403' 0 pass
check ' 404 \n' 0 pass
check '502' 0 unknown
check 'HTTP 200 OK' 0 unknown
check '' 28 unknown
((fail == 0)) && echo "PASS e03-probe"
exit $fail
