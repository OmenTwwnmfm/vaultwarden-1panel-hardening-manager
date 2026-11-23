#!/usr/bin/env bash
# 测试公共函数：临时环境、命令桩、读取报告字段（由 tests/test-*.sh source，不单独运行）
# shellcheck disable=SC2034

# mk_env：创建临时目录与配置并导出 vhm 环境变量；根目录为 $T
mk_env() {
  T=$(mktemp -d)
  mkdir -p "$T/bin" "$T/data" "$T/state"
  export VH_STATE="$T/state" VH_LOCK="$T/lock" VH_LOG=/dev/null VH_CONF="$T/conf" VBM_CONF=/nonexistent
  printf 'VW_DATA_DIR="%s"\nVW_CONTAINER="vw"\n' "$T/data" >"$VH_CONF"
  unset VH_LOCK_HELD VH_ASSUME_YES
}

# stub NAME BODY：在 $T/bin 下生成命令桩
stub() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$T/bin/$1"
  chmod +x "$T/bin/$1"
}

# run_audit DOMAIN：在桩命令优先的 PATH 下运行指定域审计
run_audit() {
  rm -f "$VH_STATE/reports/latest.json"
  PATH="$T/bin:$PATH" bash scripts/vh-audit.sh --domain "$1" >/dev/null 2>&1 || true
}

# field ID [KEY]：读取最新报告中某检查项的字段（默认 status）；无报告输出 missing
field() {
  [[ -e "$VH_STATE/reports/latest.json" ]] || { echo missing; return 0; }
  python3 - "$VH_STATE/reports/latest.json" "$1" "${2:-status}" <<'PY'
import json, sys
rows = {r["id"]: r for r in json.load(open(sys.argv[1], encoding="utf-8"))["results"]}
print(rows.get(sys.argv[2], {}).get(sys.argv[3], "missing"))
PY
}
