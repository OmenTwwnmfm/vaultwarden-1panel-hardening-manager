#!/usr/bin/env bash
# vaultwarden-1panel-hardening-manager 安装/启动入口
# 用法：sudo bash ./run.sh
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BIN=/usr/local/bin/vhm

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "[错误] 请使用 root 运行：sudo bash ./run.sh" >&2
  exit 1
fi

# 拒绝从普通用户可写的目录以 root 运行（防止被替换脚本提权）
check_path_safe() {
  local p="$1"
  while [[ -n "$p" && "$p" != "/" ]]; do
    local owner mode
    owner=$(stat -c '%u' "$p")
    mode=$(stat -c '%a' "$p")
    if [[ "$owner" != "0" ]] || (( (8#$mode & 8#022) != 0 )); then
      echo "[错误] $p 不是 root 所有或可被他人写入；请将仓库放到 /opt 下（root 所有、755）。" >&2
      exit 1
    fi
    p=$(dirname "$p")
  done
}
check_path_safe "$REPO_DIR"

install -d -m 755 /usr/local/bin
cat >"$BIN.tmp" <<EOF
#!/usr/bin/env bash
exec bash '$REPO_DIR/scripts/vh-launcher.sh' "\$@"
EOF
chmod 755 "$BIN.tmp"
mv -f "$BIN.tmp" "$BIN"
echo "[信息] 已安装/修复全局命令：$BIN"

exec bash "$REPO_DIR/scripts/vh-launcher.sh" "$@"
