#!/usr/bin/env bash
# 脱敏诊断：只输出版本、状态、路径和配置项名称，不输出任何秘密值，可直接贴进 GitHub Issue
set -Euo pipefail
VH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/vh-common.sh
source "$VH_DIR/vh-common.sh"

yn() { if "$@" >/dev/null 2>&1; then echo 是; else echo 否; fi; }

{
  echo "## vhm 诊断 · v$VH_VERSION · $(date -u +%FT%TZ)"
  echo
  echo "### 系统"
  echo "- 系统：$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  echo "- 内核：$(uname -r)"
  echo "- systemd：$(systemctl --version 2>/dev/null | head -n1 || echo 不可用)"
  echo "- Docker：$(docker version -f '{{.Server.Version}}' 2>/dev/null || echo 不可用)"
  echo "- 1Panel：$([[ -d /opt/1panel ]] && echo 已检测 || echo 未检测)"
  echo "- vbm：$(vbm_installed && echo 已安装 || echo 未安装)"
  echo "- 时间同步：$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo 未知)"
  echo
  echo "### SSH"
  echo "- sshd -t：$(sshd_test >/dev/null 2>&1 && echo 通过 || echo 未通过)"
  echo "- 服务：$(ssh_service) · socket 激活：$(yn ssh_socket_used)"
  for k in port passwordauthentication pubkeyauthentication permitrootlogin kbdinteractiveauthentication usepam authenticationmethods; do
    echo "- $k：$(sshd_get "$k" | paste -sd' ')"
  done
  echo "- PAM 动态口令：$(yn tfa_pam_on) · root 已绑定：$([[ -f $GA_FILE ]] && echo 是 || echo 否)"
  echo "- vhm drop-in：$([[ -f $SSHD_DROPIN ]] && echo "$SSHD_DROPIN（$(grep -cvE '^#|^$' "$SSHD_DROPIN") 项）" || echo 无)"
  echo "- drop-in 目录中的文件：$(ls "$(dirname "$SSHD_DROPIN")" 2>/dev/null | paste -sd' ')"
  echo
  echo "### 防火墙 / Fail2Ban"
  echo "- 防火墙：$(fw_label)"
  echo "- 1Panel Docker 端口访问控制：$(docker_guard_on && echo 已启用 || echo 未检测到)"
  echo "- Fail2Ban：$(systemctl is-active fail2ban 2>/dev/null || echo 未安装) · jail：$([[ -f $F2B_JAIL ]] && echo "$F2B_JAIL" || echo 无)"
  echo
  echo "### 1Panel"
  if panel_installed; then
    echo "- 版本：$(panel_version || echo 未知)"
    echo "- 服务：$(for u in $(panel_units); do printf '%s=%s ' "$u" "$(systemctl is-active "$u" 2>/dev/null)"; done)"
    purl=$(panel_url)
    echo "- 面板端口：$(panel_port_of "$purl") · 协议：${purl%%:*} · 安全入口：$([[ -n $(panel_entrance_of "$purl") ]] && echo 已设置 || echo 未设置)"
    echo "- reset 子命令：$(1pctl reset 2>&1 | awk '/^  [a-z]+ /{ printf "%s ", $1 }')"
  else
    echo "- 未安装（找不到 1pctl）"
  fi
  echo
  echo "### Vaultwarden"
  if load_instance 2>/dev/null; then
    echo "- 实例：$VW_CONTAINER"
    echo "- 数据目录：$VW_DATA_DIR"
    echo "- 镜像：$(docker inspect -f '{{.Config.Image}}' "$VW_CONTAINER" 2>/dev/null)"
    echo "- 状态：$(docker inspect -f '{{.State.Status}}{{if .State.Health}} / {{.State.Health.Status}}{{end}}' "$VW_CONTAINER" 2>/dev/null)"
    echo "- 后台令牌类型：$(vw_admin_state)"
    echo "- 环境变量名（值已省略）：$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$VW_CONTAINER" 2>/dev/null | cut -d= -f1 | sort | paste -sd' ')"
    if [[ -r $VW_DATA_DIR/config.json ]]; then
      echo "- config.json 键名（值已省略）：$(python3 -c 'import json,sys; print(" ".join(sorted(json.load(open(sys.argv[1])))))' "$VW_DATA_DIR/config.json" 2>/dev/null || echo 解析失败)"
    else
      echo "- config.json：不存在"
    fi
  else
    echo "- 实例：未能确定"
  fi
  echo
  echo "### vhm"
  echo "- 配置：$([[ -f $VH_CONF ]] && stat -c '%U %a' "$VH_CONF" || echo 不存在)"
  echo "- 变更记录：$(find "$VH_CHANGES" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l) 条"
  echo "- 未完成的防锁死保护：$(systemctl list-timers --all --no-legend 'vhm-guard-*' 2>/dev/null | wc -l)"
  echo "- 旧版巡检残留：$([[ -f /etc/systemd/system/vaultwarden-hardening-watch.timer ]] && echo 有 || echo 无)"
} | while IFS= read -r l; do redact "$l"; done
