#!/usr/bin/env bash
# 容器运行时
priv=$(docker inspect -f '{{.HostConfig.Privileged}}' "$VW_CONTAINER" 2>/dev/null)
caps=$(docker inspect -f '{{.HostConfig.CapAdd}}' "$VW_CONTAINER" 2>/dev/null)
sock=$(docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' "$VW_CONTAINER" 2>/dev/null | grep -o 'docker.sock' || true)
issues=()
[[ "$priv" == true ]] && issues+=(privileged)
[[ -n "$caps" && "$caps" != "[]" && "$caps" != "<no value>" ]] && issues+=("cap_add=$caps")
[[ -n "$sock" ]] && issues+=(docker.sock)
if ((${#issues[@]})); then
  emit C-01 P0 fail 1panel report "容器特权" "${issues[*]}"
else
  emit C-01 P0 pass 1panel report "容器特权" "无特权、无额外能力、未挂载 docker.sock"
fi

img=$(docker inspect -f '{{.Config.Image}}' "$VW_CONTAINER" 2>/dev/null)
if [[ "$img" == *@sha256:* ]]; then
  emit C-02 P1 pass 1panel guided "镜像固定" "$img"
elif [[ "$img" == *:latest || "$img" != *:* ]]; then
  emit C-02 P1 warn 1panel guided "镜像固定" "$img 使用 latest/无 tag"
else
  emit C-02 P1 pass 1panel guided "镜像固定" "$img"
fi
:
