#!/usr/bin/env bash
# 1Panel 面板
panel_conf() { command -v 1pctl >/dev/null 2>&1 && 1pctl user-info 2>/dev/null; }

info=$(panel_conf || true)
if [[ -z "$info" ]]; then
  emit P-01 P0 unknown 1panel guided "1Panel 面板端口暴露" "未找到 1pctl"
  emit P-02 P1 unknown 1panel guided "面板安全入口/访问限制" "未找到 1pctl"
  emit P-03 P1 unknown 1panel guided "面板 MFA" "未找到 1pctl"
  emit P-04 P1 unknown 1panel guided "1Panel 版本" "未找到 1pctl"
  return 0
fi

port=$(sed -nE 's/.*(端口|port)[^0-9]*([0-9]+).*/\2/Ip' <<<"$info" | head -n1)
entrance=$(sed -nE 's/.*(安全入口|entrance)[:：][[:space:]]*(.*)/\2/Ip' <<<"$info" | head -n1)
if [[ -n "$port" ]] && ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "^(0\.0\.0\.0|\*|\[::\]):$port$"; then
  emit P-01 P0 fail 1panel guided "1Panel 面板端口暴露" "面板端口 $port 监听所有地址"
else
  emit P-01 P0 pass 1panel guided "1Panel 面板端口暴露" "端口 ${port:-?} 未监听公网地址"
fi
if [[ -z "$entrance" ]]; then
  emit P-02 P1 fail 1panel guided "面板安全入口/访问限制" "未设置安全入口"
else
  emit P-02 P1 pass 1panel guided "面板安全入口/访问限制" "已设置安全入口"
fi
emit P-03 P1 unknown 1panel guided "面板 MFA" "需在面板「设置→安全」人工确认"
ver=$(1pctl version 2>/dev/null | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
emit P-04 P1 unknown 1panel guided "1Panel 版本" "当前 ${ver:-unknown}，请与官方最新版比对"
