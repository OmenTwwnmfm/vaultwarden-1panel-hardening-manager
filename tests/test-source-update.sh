#!/usr/bin/env bash
# 断言源码更新：只认官方 origin；只在 main、工作区干净、可快进时报告新版本；检查本身不改源码；
# 启动和 [27] 都必须预览后收到 yes 才快进；签名检查和 AUTO_UPDATE 取值容错
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export VH_STATE="$T/state" VH_LOG=/dev/null VH_CONF="$T/hardening.conf"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"
mkdir -p "$HOME"
# shellcheck source=scripts/vh-manager.sh
source scripts/vh-manager.sh
fail=0
g() { git -c commit.gpgsign=false -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

# origin 校验（不联网）
g init "$T/o"
for u in "https://github.com/$VH_OFFICIAL_REPO" "https://github.com/$VH_OFFICIAL_REPO.git" "git@github.com:$VH_OFFICIAL_REPO.git" "ssh://git@github.com/$VH_OFFICIAL_REPO/"; do
  git -C "$T/o" remote remove origin 2>/dev/null
  git -C "$T/o" remote add origin "$u"
  source_origin_ok "$T/o" 2>/dev/null || { echo "FAIL 拒绝了官方地址 $u"; fail=1; }
done
for u in "https://github.com/evil/$VH_OFFICIAL_REPO" "https://github.com/${VH_OFFICIAL_REPO}-fork" "https://example.com/$VH_OFFICIAL_REPO"; do
  git -C "$T/o" remote remove origin 2>/dev/null
  git -C "$T/o" remote add origin "$u"
  warning=$(source_origin_ok "$T/o" 2>&1) && { echo "FAIL 接受了非官方地址 $u"; fail=1; }
  [[ $warning != *"$u"* ]] || { echo "FAIL 提示回显了被拒绝的 origin"; fail=1; }
done

# 本地仓库模拟 GitHub：R 为远端，C 为用户的克隆，W 用于向远端推送新版本
g init --bare "$T/R.git"
g clone "$T/R.git" "$T/W"
mkdir -p "$T/W/scripts"
echo 0.1.0 >"$T/W/VERSION"
echo fixture >"$T/W/README.md"
echo '- Already installed change' >"$T/W/CHANGELOG.md"
g -C "$T/W" add -A
g -C "$T/W" commit -m v1
g -C "$T/W" push origin HEAD:main
g clone -b main "$T/R.git" "$T/C"
fixture_origin=$(git -C "$T/C" remote get-url origin) || exit 1
source_origin_ok() { [[ $(git -C "$1" remote get-url origin) == "$fixture_origin" ]]; }
mkdir -p "$T/C/scripts"
VH_DIR="$T/C/scripts"
push_new() { echo "$1" >"$T/W/VERSION" && g -C "$T/W" commit -am "$1" && g -C "$T/W" push origin HEAD:main; }
rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }

[[ $(rc_of source_check) == 0 ]] || { echo "FAIL 已是最新时返回值不是 0"; fail=1; }
push_new 0.2.0
head_before=$(git -C "$T/C" rev-parse HEAD)
[[ $(rc_of source_check) == "$VH_SOURCE_AVAILABLE" ]] || { echo "FAIL 有新版本时未报告"; fail=1; }
source_check >/dev/null 2>&1
[[ $(git -C "$T/C" rev-parse HEAD) == "$head_before" ]] || { echo "FAIL 检查更新时修改了源码"; fail=1; }
[[ $(source_commit_label "$UPD_TARGET") == v0.2.0* ]] || { echo 'FAIL 目标版本号读取错误'; fail=1; }
pending=$(source_show_pending)
[[ $pending == *0.2.0* ]] || { echo "FAIL 未列出待更新的提交"; fail=1; }

# 要求签名：未签名的提交不能更新
echo 'UPDATE_REQUIRE_SIGNED="1"' >"$VH_CONF"
[[ $(rc_of source_apply) == 1 ]] || { echo "FAIL 未签名的提交被接受"; fail=1; }
[[ $(git -C "$T/C" rev-parse HEAD) == "$head_before" ]] || { echo "FAIL 签名校验失败后源码被修改"; fail=1; }
: >"$VH_CONF"

source_check >/dev/null 2>&1
[[ $(rc_of source_apply) == "$VH_SOURCE_UPDATED" ]] || { echo "FAIL 快进更新失败"; fail=1; }
[[ $(cat "$T/C/VERSION") == 0.2.0 ]] || { echo "FAIL 更新后版本不对"; fail=1; }

push_new 0.3.0
source_check >/dev/null 2>&1
head_before=$(git -C "$T/C" rev-parse HEAD)
echo dirty >"$T/C/README.md"
[[ $(rc_of source_check) == 1 ]] || { echo "FAIL 工作区有改动时仍报告可更新"; fail=1; }
[[ $(rc_of source_apply) == 1 ]] || { echo "FAIL 确认前出现不冲突的本地修改时仍执行更新"; fail=1; }
[[ $(git -C "$T/C" rev-parse HEAD) == "$head_before" && $(cat "$T/C/README.md") == dirty ]] || { echo "FAIL 更新改变了有本地编辑的工作区"; fail=1; }
echo fixture >"$T/C/README.md"

# 不在 main 分支：不更新
g -C "$T/C" checkout -b other
[[ $(rc_of source_check) == 1 ]] || { echo "FAIL 非 main 分支仍报告可更新"; fail=1; }
[[ $(rc_of source_apply) == 1 ]] || { echo "FAIL 确认前切换分支时仍执行更新"; fail=1; }
[[ $(git -C "$T/C" rev-parse HEAD) == "$head_before" ]] || { echo "FAIL 更新改变了其他分支"; fail=1; }
g -C "$T/C" checkout main

git -C "$T/C" remote set-url origin "$T/changed.git"
[[ $(rc_of source_apply) == 1 ]] || { echo "FAIL 确认前修改 origin 时仍执行更新"; fail=1; }
git -C "$T/C" remote set-url origin "$fixture_origin"

(
  git() {
    [[ ${3:-} == status ]] && return 128
    command git "$@"
  }
  git -C "$T/C" status >/dev/null 2>&1 && exit 1
  [[ $(rc_of source_check) == 1 && $(rc_of source_apply) == 1 ]]
) || { echo "FAIL 无法读取工作区状态时未停止更新"; fail=1; }

g -C "$T/C" merge --ff-only "$UPD_TARGET"
[[ $(rc_of source_apply) == 1 ]] || { echo "FAIL HEAD 改变后仍尝试执行已过期的更新"; fail=1; }

# 本地有远端没有的提交：不能快进
push_new 0.4.0
echo local >"$T/C/local.txt"
g -C "$T/C" add local.txt
g -C "$T/C" commit -m local
[[ $(rc_of source_check) == 1 ]] || { echo "FAIL 无法快进时仍报告可更新"; fail=1; }

# 网络不可用：跳过
git -C "$T/C" remote set-url origin "$T/missing.git"
fixture_origin=$(git -C "$T/C" remote get-url origin) || exit 1
[[ $(rc_of source_check) == 1 ]] || { echo "FAIL 无法连接远端时返回值不是 1"; fail=1; }

# 更新方式
[[ $(update_mode) == notify ]] || { echo "FAIL 默认更新方式不是 notify"; fail=1; }
echo 'AUTO_UPDATE="off"' >"$VH_CONF"
[[ $(update_mode) == off ]] || { echo "FAIL AUTO_UPDATE=off 未生效"; fail=1; }
echo 'AUTO_UPDATE="yes please"' >"$VH_CONF"
[[ $(update_mode) == notify ]] || { echo "FAIL 非法的 AUTO_UPDATE 没有退回 notify"; fail=1; }

# 使用同一远端的新克隆验证菜单行为，保留真实 fetch、预览和快进。
g clone -b main "$T/R.git" "$T/M"
mkdir -p "$T/M/scripts"
VH_DIR="$T/M/scripts"
VH_VERSION=$(cat "$T/M/VERSION")
fixture_origin=$(git -C "$T/M" remote get-url origin) || exit 1
installed=$(git -C "$T/M" rev-parse HEAD)
printf '\n## 0.5.0\n- New item pending confirmation\n' >>"$T/W/CHANGELOG.md"
push_new 0.5.0
candidate=$(git -C "$T/W" rev-parse HEAD)
candidate_short=$(git -C "$T/W" rev-parse --short HEAD)
export VH_ASSUME_YES=1
unset VHM_AUTO_UPDATE_CHECKED
pause() { :; }
sleep() { :; }
restart_menu() { git -C "$T/M" rev-parse HEAD >>"$T/restarts"; }

check_preview() {
  local out=$1 label=$2
  if [[ $out != *"当前 v$VH_VERSION"*v0.5.0*"$candidate_short"* ||
        $out != *'New item pending confirmation'*'更新后菜单会重新加载'* ||
        $out == *'Already installed change'* ]]; then
    printf 'FAIL %s 未在确认前预览候选版本、提交和新增说明\n%s\n' "$label" "$out"
    fail=1
  fi
}

check_unchanged() {
  if [[ $(git -C "$T/M" rev-parse HEAD) != "$installed" ||
        $(cat "$T/M/VERSION") != "$VH_VERSION" || -e $T/restarts ]]; then
    echo "FAIL $1 未经确认修改源码或重载菜单"
    fail=1
  fi
}

# off 必须连 fetch 都不做，但从 [27] 仍然可以检查并取消。
echo 'AUTO_UPDATE="off"' >"$VH_CONF"
output=$(auto_update_source </dev/null 2>&1)
[[ -z $output && $(git -C "$T/M" rev-parse origin/main) == "$installed" ]] || { echo "FAIL off 启动时检查了更新"; fail=1; }
check_unchanged 'off 启动'
output=$(update_source <<<no 2>&1)
check_preview "$output" '[27]'
check_unchanged '[27] 输入 no'

# 显式拒绝和 EOF 都不能被通用确认快捷方式绕过。
for mode in apply default; do
  if [[ $mode == apply ]]; then echo 'AUTO_UPDATE="apply"' >"$VH_CONF"; else : >"$VH_CONF"; fi
  output=$(VH_VERSION=0.0.0 auto_update_source <<<no 2>&1)
  check_preview "$output" "$mode"
  check_unchanged "$mode 输入 no"
  output=$(auto_update_source </dev/null 2>&1)
  check_preview "$output" "$mode"
  check_unchanged "$mode 遇到 EOF"
done

echo 'AUTO_UPDATE="apply"' >"$VH_CONF"
output=$(
  git() {
    case ${4:-} in diff | log) return 128 ;; esac
    command git "$@"
  }
  auto_update_source <<<yes 2>&1
)
[[ $output == *'无法读取更新内容'* && $output != *'更新后菜单会重新加载'* ]] || { echo 'FAIL 缺少更新预览时仍尝试确认'; fail=1; }
check_unchanged '预览失败时输入 yes'

output=$(auto_update_source <<<yes 2>&1)
check_preview "$output" 'apply 输入 yes'
[[ $(git -C "$T/M" rev-parse HEAD) == "$candidate" && $(cat "$T/M/VERSION") == 0.5.0 &&
  -f $T/restarts && $(cat "$T/restarts") == "$candidate" ]] || { echo "FAIL 输入 yes 后未快进到预览提交并重载一次"; fail=1; }

((fail == 0)) && echo "PASS source-update"
exit $fail
