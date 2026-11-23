#!/usr/bin/env bash
# 查看 / 导出最新报告
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"
R="$VH_STATE/reports"
[[ -r "$R/latest.md" ]] || die "没有报告，请先运行 [03]"
case "${1:-show}" in
  show) cat "$R/latest.md" ;;
  export)
    dest="${2:-$PWD}"
    install -m 600 "$(readlink -f "$R/latest.md")" "$dest/"
    install -m 600 "$(readlink -f "$R/latest.json")" "$dest/"
    log_ok "已导出到 $dest" ;;
  *) die "用法：vh-report.sh show|export [目录]" ;;
esac
