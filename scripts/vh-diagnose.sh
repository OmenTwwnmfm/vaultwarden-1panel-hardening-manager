#!/usr/bin/env bash
# 脱敏诊断：只输出变量名、分类结果、路径，不输出秘密值
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"
{
  echo "## vhm 诊断 · $VH_VERSION · $(date -u +%FT%TZ)"
  echo "- 系统：$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  echo "- 内核：$(uname -r)"
  echo "- Docker：$(docker version -f '{{.Server.Version}}' 2>/dev/null || echo 不可用)"
  echo "- 1Panel：$([[ -d /opt/1panel ]] && echo 已检测 || echo 未检测)"
  echo "- vbm：$(command -v vbm >/dev/null && echo 已安装 || echo 未安装)"
  echo "- 配置：$([[ -f $VH_CONF ]] && stat -c '%U %a' "$VH_CONF" || echo 不存在)"
  if load_instance 2>/dev/null; then
    echo "- 实例：$VW_CONTAINER"
    echo "- 数据目录：$VW_DATA_DIR"
    echo "- 环境变量名（值已省略）："
    docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$VW_CONTAINER" 2>/dev/null | cut -d= -f1 | sort | sed 's/^/    /'
  else
    echo "- 实例：未能确定"
  fi
  echo "- 最新报告：$(readlink -f "$VH_STATE/reports/latest.json" 2>/dev/null || echo 无)"
} | while IFS= read -r l; do redact "$l"; done
