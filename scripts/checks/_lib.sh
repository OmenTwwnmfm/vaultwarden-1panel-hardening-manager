#!/usr/bin/env bash
# 检查项公共函数：emit 输出一行 TSV，由 vh_rules.py 汇总为 JSON
# emit ID SEVERITY STATUS OWNER FIX_TYPE TITLE EVIDENCE
# STATUS ∈ pass|fail|warn|unknown；EVIDENCE 自动脱敏
emit() {
  local ev
  ev=$(redact "${7:-}" | tr '\t\n' '  ')
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$ev" >>"$VH_RESULTS"
}

# 读取容器环境变量（只读）
vw_env() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$VW_CONTAINER" 2>/dev/null |
    sed -nE "s/^$1=(.*)$/\1/p" | tail -n1
}

# 读取 /data/config.json 键（admin 页面保存的设置，优先于环境变量）
vw_cfg() {
  local f="$VW_DATA_DIR/config.json"
  [[ -r "$f" ]] || return 0
  python3 - "$f" "$1" <<'PY' 2>/dev/null || true
import json,sys
try:
    v=json.load(open(sys.argv[1])).get(sys.argv[2])
except Exception:
    sys.exit(0)
if v is not None:
    print(str(v).lower() if isinstance(v,bool) else v)
PY
}

# 有效值：config.json > env > 默认
vw_eff() {
  local k_cfg=$1 k_env=$2 def=$3 v
  v=$(vw_cfg "$k_cfg"); [[ -n "$v" ]] && { echo "$v"; return; }
  v=$(vw_env "$k_env"); [[ -n "$v" ]] && { echo "${v,,}"; return; }
  echo "$def"
}
