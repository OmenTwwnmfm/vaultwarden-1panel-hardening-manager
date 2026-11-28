# shellcheck shell=bash
# shellcheck disable=SC2034
# 项目源码更新：检查 GitHub main、展示待更新内容、确认后快进；由 vh-common.sh 加载，不要单独执行
#
# 更新方式由配置文件中的 AUTO_UPDATE 决定：
#   notify（默认）进入菜单时检查，有更新时先展示内容，输入 yes 才更新
#   apply         旧配置值，按 notify 处理
#   off           不自动检查，只能在 [27] 手动检查
# UPDATE_REQUIRE_SIGNED=1 时，只接受 git verify-commit 校验通过的新版本。

VH_SOURCE_UPDATED=10
VH_SOURCE_AVAILABLE=11
VH_OFFICIAL_REPO=OmenTwwnmfm/vaultwarden-hardening-manager
UPD_ROOT="" UPD_BEFORE="" UPD_TARGET=""

source_root() { cd "$VH_DIR/.." && pwd -P; }

update_mode() {
  local m
  m=$(conf_get AUTO_UPDATE 2>/dev/null || true)
  case $m in
    off) echo off ;;
    *) echo notify ;;
  esac
}

source_origin_ok() { # source_origin_ok 仓库目录：origin 是否指向官方仓库
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null || true)
  url=${url%/}
  url=${url%.git}
  case $url in
    "https://github.com/$VH_OFFICIAL_REPO" | "git@github.com:$VH_OFFICIAL_REPO" | "ssh://git@github.com/$VH_OFFICIAL_REPO") return 0 ;;
  esac
  log_warn "origin 不是官方仓库，已停止更新；请核对地址：https://github.com/$VH_OFFICIAL_REPO"
  return 1
}

source_worktree_ok() {
  local root=$1 branch status
  branch=$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null || true)
  [[ $branch == main ]] || { log_warn "当前分支为 ${branch:-分离的 HEAD}，只在 main 分支上更新"; return 1; }
  if ! status=$(git -C "$root" status --porcelain --untracked-files=no 2>/dev/null); then
    log_warn "无法检查源码目录状态，未更新：$root"
    return 1
  fi
  if [[ -n $status ]]; then
    log_warn "源码目录有未提交的修改，未更新：$root"
    return 1
  fi
}

# 检查是否有可快进的新版本，不修改源码。
# 返回 0 = 已是最新；VH_SOURCE_AVAILABLE = 有新版本（UPD_BEFORE..UPD_TARGET）；1 = 跳过或失败（已输出原因）。
# 只在以下条件全部满足时才算可更新：origin 指向官方仓库、当前在 main 分支、已跟踪文件没有本地改动、
# 本地提交都已包含在远端（只快进，不合并）。抓取限时 30 秒且禁止交互式输入凭据。
source_check() {
  UPD_ROOT="" UPD_BEFORE="" UPD_TARGET=""
  local root before target
  command -v git >/dev/null 2>&1 || { log_warn "未安装 git，无法检查更新"; return 1; }
  root=$(source_root) || return 1
  [[ $(git -C "$root" rev-parse --is-inside-work-tree 2>/dev/null) == true ]] || { log_warn "$root 不是 git 工作区，无法检查更新"; return 1; }
  source_origin_ok "$root" || return 1
  source_worktree_ok "$root" || return 1
  before=$(git -C "$root" rev-parse --verify HEAD) || return 1
  if ! GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes" \
    timeout 30 git -C "$root" fetch --quiet --no-tags origin main </dev/null 2>/dev/null; then
    log_warn "暂时无法连接 GitHub，继续使用本地 v$VH_VERSION"
    return 1
  fi
  target=$(git -C "$root" rev-parse --verify 'FETCH_HEAD^{commit}') || return 1
  [[ $before == "$target" ]] && return 0
  if ! git -C "$root" merge-base --is-ancestor "$before" "$target"; then
    log_warn "本地有远端没有的提交，无法快进更新"
    return 1
  fi
  UPD_ROOT=$root UPD_BEFORE=$before UPD_TARGET=$target
  return "$VH_SOURCE_AVAILABLE"
}

source_commit_label() {
  local commit=$1 version
  if version=$(git -C "$UPD_ROOT" show "$commit:VERSION" 2>/dev/null) && [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'v%s（%.12s）\n' "$version" "$commit"
  else
    printf '提交 %.12s\n' "$commit"
  fi
}

source_preview_text() { LC_ALL=C tr -d '\000-\011\013-\037\177'; } # 保留换行与 UTF-8，删除终端控制字符

source_show_pending() {
  local notes log
  notes=$(git -C "$UPD_ROOT" --no-pager diff --no-ext-diff --no-textconv --no-color --no-renames -U0 \
    "$UPD_BEFORE" "$UPD_TARGET" -- CHANGELOG.md 2>/dev/null | source_preview_text | awk '
      /^@@ / { hunk=1; next }
      hunk && /^\+/ && substr($0, 2) ~ /[^[:space:]]/ { if (++n <= 16) print "    " substr($0, 2) }
      END { if (n > 16) print "    ……" }
    ') || notes=""
  log=$(git -C "$UPD_ROOT" --no-pager log --oneline --no-decorate --no-color --no-show-signature -n 21 \
    "$UPD_BEFORE..$UPD_TARGET" 2>/dev/null | source_preview_text) || log=""
  if [[ -z $notes && -z $log ]]; then
    log_warn '无法读取更新内容，已取消本次更新'
    return 1
  fi
  if [[ -n $notes ]]; then
    printf '  更新内容（CHANGELOG）：\n%s\n' "$notes"
  fi
  if [[ -n $log ]]; then
    echo '  待更新提交：'
    awk 'NR <= 20 { print "    " $0 } END { if (NR > 20) print "    ……" }' <<<"$log"
  fi
  echo "  完整更新日志：https://github.com/$VH_OFFICIAL_REPO/blob/$UPD_TARGET/CHANGELOG.md"
}

source_verify() {
  [[ $(conf_get UPDATE_REQUIRE_SIGNED 2>/dev/null || true) == 1 ]] || return 0
  if ! git -C "$UPD_ROOT" verify-commit "$UPD_TARGET" >/dev/null 2>&1; then
    log_err "新版本提交 ${UPD_TARGET:0:12} 没有通过签名校验（UPDATE_REQUIRE_SIGNED=1），未更新"
    return 1
  fi
}

# 快进到 source_check 找到的新版本。返回 VH_SOURCE_UPDATED = 已更新；1 = 失败（源码保持不变）。
source_apply() {
  local head
  [[ -n $UPD_ROOT && -n $UPD_BEFORE && -n $UPD_TARGET ]] || { log_err "内部错误：没有待更新的提交"; return 1; }
  source_verify || return 1
  source_origin_ok "$UPD_ROOT" || return 1
  source_worktree_ok "$UPD_ROOT" || return 1
  head=$(git -C "$UPD_ROOT" rev-parse --verify HEAD 2>/dev/null) || head=""
  [[ $head == "$UPD_BEFORE" ]] || { log_warn "检查更新后当前提交已变化，请重新检查更新"; return 1; }
  git -C "$UPD_ROOT" merge --ff-only --quiet "$UPD_TARGET" || { log_warn "快进更新失败，源码保持不变"; return 1; }
  return "$VH_SOURCE_UPDATED"
}
