#!/usr/bin/env bash
# 主机 / SSH
sshd_eff=$(sshd -T 2>/dev/null || true)
if [[ -z "$sshd_eff" ]]; then
  emit N-01 P1 unknown host guided "SSH 登录方式" "无法读取 sshd -T"
else
  pa=$(awk '$1=="passwordauthentication"{print $2}' <<<"$sshd_eff")
  prl=$(awk '$1=="permitrootlogin"{print $2}' <<<"$sshd_eff")
  if [[ "$pa" == yes || "$prl" == yes ]]; then
    emit N-01 P1 fail host guided "SSH 登录方式" "PasswordAuthentication=$pa PermitRootLogin=$prl"
  else
    emit N-01 P1 pass host guided "SSH 登录方式" "PasswordAuthentication=$pa PermitRootLogin=$prl"
  fi
fi

fw=none
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
  fw=ufw
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  fw=firewalld
elif command -v nft >/dev/null 2>&1 && [[ $(nft list ruleset 2>/dev/null | wc -l) -gt 5 ]]; then
  fw=nftables
fi
if [[ $fw == none ]]; then
  emit N-02 P1 fail host guided "主机防火墙" "未检测到启用的防火墙"
else
  emit N-02 P1 pass host guided "主机防火墙" "$fw 已启用（22 端口范围请人工确认）"
fi

if systemctl is-enabled unattended-upgrades >/dev/null 2>&1 || systemctl is-enabled dnf-automatic.timer >/dev/null 2>&1; then
  emit N-03 P2 pass host guided "自动安全更新" "已启用"
else
  emit N-03 P2 warn host guided "自动安全更新" "未启用 unattended-upgrades/dnf-automatic"
fi
:
