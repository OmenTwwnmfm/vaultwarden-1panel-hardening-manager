#!/usr/bin/env bash
# 断言 config.json 写入：保留其他键、更新/删除、权限 600、损坏文件不覆盖；有效值优先级与后台状态判定
set -Euo pipefail
cd "$(dirname "$0")/.." || exit 1
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export VH_STATE="$T/state" VH_LOG=/dev/null
# shellcheck source=scripts/vh-common.sh
source scripts/vh-common.sh
fail=0
VW_DATA_DIR=$T VW_CONTAINER=none-vhm-test
docker() { return 1; } # 无容器：环境变量为空
printf '{"domain": "https://v.example.com", "signups_allowed": true, "sends_allowed": true}\n' >"$T/config.json"
printf 'signups_allowed\tfalse\nsends_allowed\t__DELETE__\nadmin_token\t""\n' | vw_config_write || { echo "FAIL 写入失败"; fail=1; }
[[ $(vw_cfg domain) == https://v.example.com ]] || { echo "FAIL 其他键丢失"; fail=1; }
[[ $(vw_eff signups_allowed SIGNUPS_ALLOWED true) == false ]] || { echo "FAIL 未更新"; fail=1; }
vw_cfg_has sends_allowed && { echo "FAIL 未删除"; fail=1; }
vw_cfg_has admin_token || { echo "FAIL 空串键未写入"; fail=1; }
[[ $(vw_admin_state) == off ]] || { echo "FAIL 空令牌应为 off"; fail=1; }
[[ $(stat -c %a "$T/config.json") == 600 ]] || { echo "FAIL 权限不是 600"; fail=1; }
printf 'admin_token\t"$argon2id$v=19$m=19456,t=2,p=1$c2FsdA$aGFzaA"\n' | vw_config_write
[[ $(vw_admin_state) == argon2 ]] || { echo "FAIL 未识别 argon2"; fail=1; }
printf 'disable_admin_token\ttrue\n' | vw_config_write
[[ $(vw_admin_state) == notoken ]] || { echo "FAIL 未识别免令牌"; fail=1; }
[[ $(vw_eff sends_allowed SENDS_ALLOWED true) == true ]] || { echo "FAIL 默认值错误"; fail=1; }
printf '{broken' >"$T/config.json"
printf 'signups_allowed\tfalse\n' | vw_config_write 2>/dev/null && { echo "FAIL 覆盖了损坏的 config.json"; fail=1; }
[[ $(cat "$T/config.json") == '{broken' ]] || { echo "FAIL 损坏文件被修改"; fail=1; }
((fail == 0)) && echo "PASS vw-config"
exit $fail
