#!/usr/bin/env bash
# 全部 pass 的报告生成的计划必须为空
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/reports"
printf 'A-01\tP0\tpass\t1panel\tguided\tx\tok\nD-02\tP1\tpass\thost\tauto\tx\tok\n' >"$T/r.tsv"
python3 scripts/vh_rules.py report "$T/r.tsv" "$T/reports/a.json" "$T/reports/a.md" >/dev/null
ln -s "$T/reports/a.json" "$T/reports/latest.json"
for _ in 1 2; do VH_STATE="$T" VH_LOG=/dev/null bash scripts/vh-plan.sh >/dev/null; done
python3 -c 'import json,sys; sys.exit(len(json.load(open(sys.argv[1]))["items"]))' "$T/plan.json" ||
  { echo "FAIL 计划非空"; exit 1; }
echo "PASS plan-idempotent"
