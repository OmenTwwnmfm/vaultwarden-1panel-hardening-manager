#!/usr/bin/env bash
# Vaultwarden 应用配置（env + config.json）
sig=$(vw_eff signups_allowed SIGNUPS_ALLOWED true)
if [[ "$sig" == false ]]; then
  emit A-01 P0 pass 1panel guided "关闭开放注册" "SIGNUPS_ALLOWED=false"
else
  emit A-01 P0 fail 1panel guided "关闭开放注册" "SIGNUPS_ALLOWED=$sig"
fi

# 证据避免写成「*_TOKEN=值」形式，否则会被脱敏规则抹掉
dis=$(vw_eff disable_admin_token DISABLE_ADMIN_TOKEN false)
if [[ "$dis" == true ]]; then
  emit A-02 P0 fail 1panel guided "admin 免令牌" "免令牌访问已开启（DISABLE_ADMIN_TOKEN 为 true）"
else
  emit A-02 P0 pass 1panel guided "admin 免令牌" "免令牌访问未开启"
fi

# ADMIN_TOKEN：只分类，不输出值
tok=$(vw_cfg admin_token)
[[ -z "$tok" ]] && tok=$(vw_env ADMIN_TOKEN)
if [[ -z "$tok" ]]; then
  emit A-03 P1 pass 1panel guided "ADMIN_TOKEN 强度" "空（/admin 已禁用）"
elif [[ "$tok" == '$argon2'* ]]; then
  emit A-03 P1 pass 1panel guided "ADMIN_TOKEN 强度" "argon2 哈希"
else
  emit A-03 P1 fail 1panel guided "ADMIN_TOKEN 强度" "明文，长度 ${#tok}"
fi
unset tok

bad=()
[[ $(vw_eff show_password_hint SHOW_PASSWORD_HINT false) == true ]] && bad+=(SHOW_PASSWORD_HINT)
[[ $(vw_eff sends_allowed SENDS_ALLOWED true) == true ]] && bad+=(SENDS_ALLOWED)
[[ $(vw_eff emergency_access_allowed EMERGENCY_ACCESS_ALLOWED true) == true ]] && bad+=(EMERGENCY_ACCESS_ALLOWED)
[[ -z $(vw_eff org_creation_users ORG_CREATION_USERS "") ]] && bad+=(ORG_CREATION_USERS=all)
if ((${#bad[@]})); then
  emit A-04 P2 warn 1panel guided "功能面收敛" "${bad[*]}"
else
  emit A-04 P2 pass 1panel guided "功能面收敛" "已收敛"
fi

icon=$(vw_eff icon_service ICON_SERVICE internal)
if [[ "$icon" == internal ]]; then
  emit A-05 P2 pass 1panel guided "图标服务" "internal"
else
  emit A-05 P2 warn 1panel guided "图标服务" "外部服务：$icon（会泄露已存域名）"
fi
:
