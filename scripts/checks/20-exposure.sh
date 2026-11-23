#!/usr/bin/env bash
# 暴露面
# shellcheck disable=SC2016
binds=$(docker inspect -f '{{range $p,$b := .HostConfig.PortBindings}}{{range $b}}{{.HostIp}}:{{.HostPort}} {{end}}{{end}}' "$VW_CONTAINER" 2>/dev/null || true)
if [[ -z "${binds// /}" ]]; then
  emit E-01 P0 pass 1panel guided "容器端口绑定" "未发布端口"
elif grep -Eq '(^| )(0\.0\.0\.0|::)?:[0-9]+' <<<" $binds"; then
  emit E-01 P0 fail 1panel guided "容器端口绑定" "绑定所有地址：$binds（Docker 会绕过 ufw）"
else
  emit E-01 P0 pass 1panel guided "容器端口绑定" "$binds"
fi

domain=$(vw_eff domain DOMAIN "")
if [[ "$domain" == https://* ]]; then
  emit E-02 P0 pass 1panel guided "DOMAIN 使用 https" "$domain"
elif [[ -z "$domain" ]]; then
  emit E-02 P0 fail 1panel guided "DOMAIN 使用 https" "DOMAIN 未设置"
else
  emit E-02 P0 fail 1panel guided "DOMAIN 使用 https" "$domain"
fi

# E-03 外部探测约定：EXTERNAL_PROBE_URL 的响应体只包含一个 3 位 HTTP 状态码（可带空白），
# 即从外部网络访问 https://<域名>/admin 得到的状态码。2xx/3xx=可达(fail)，4xx=已拦截(pass)，其余=unknown
probe=$(conf_get EXTERNAL_PROBE_URL || true)
if [[ -z "$probe" ]]; then
  emit E-03 P0 unknown 1panel guided "/admin 公网可达" "未配置 EXTERNAL_PROBE_URL，本机自检无法证明"
else
  probe_body=$(curl_url "$probe" 2>/dev/null | head -c 64 || true)
  probe_code=$(tr -d '[:space:]' <<<"$probe_body")
  if [[ ! "$probe_code" =~ ^[1-5][0-9][0-9]$ ]]; then
    emit E-03 P0 unknown 1panel guided "/admin 公网可达" "探测失败或返回格式无效（应只返回 3 位状态码）"
  elif [[ "$probe_code" == [23]* ]]; then
    emit E-03 P0 fail 1panel guided "/admin 公网可达" "外部探测返回 $probe_code"
  elif [[ "$probe_code" == 4* ]]; then
    emit E-03 P0 pass 1panel guided "/admin 公网可达" "外部探测返回 $probe_code"
  else
    emit E-03 P0 unknown 1panel guided "/admin 公网可达" "外部探测返回 $probe_code（无法判定）"
  fi
fi
:
