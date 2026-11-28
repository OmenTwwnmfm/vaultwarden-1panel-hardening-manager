#!/usr/bin/env bash
# 断言源码更新：只认官方 origin；只在 main、工作区干净、可快进时报告新版本；检查本身不改源码；
# 确认后才快进；要求签名时拒绝未签名的提交；AUTO_UPDATE 取值容错
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export VH_STATE="$T/state" VH_LOG=/dev/null VH_CONF="$T/hardening.conf"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 HOME="$T/home"
mkdir -p "$HOME"
# shellcheck source=scripts/vh-common.sh
source scripts/vh-common.sh
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
[[ $(source_target_version) == 0.2.0 ]] || { echo "FAIL 新版本号读取错误：$(source_target_version)"; fail=1; }
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

((fail == 0)) && echo "PASS source-update"
exit $fail
