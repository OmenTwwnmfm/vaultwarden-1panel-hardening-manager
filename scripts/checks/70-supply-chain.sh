#!/usr/bin/env bash
# 版本 / 供应链
domain=$(conf_get VW_DOMAIN || true)
[[ -z "$domain" ]] && domain=$(vw_eff domain DOMAIN "" | sed -E 's#^https?://##; s#/.*##')
cur=""
[[ -n "$domain" ]] && cur=$(curl -fsS -m 10 "https://$domain/api/config" 2>/dev/null |
  python3 -c 'import json,sys; print(json.load(sys.stdin).get("server",{}).get("version",""))' 2>/dev/null || true)
latest=$(curl -fsS -m 10 https://api.github.com/repos/dani-garcia/vaultwarden/releases/latest 2>/dev/null |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' 2>/dev/null || true)
if [[ -z "$cur" || -z "$latest" ]]; then
  emit S-01 P1 unknown 1panel guided "Vaultwarden 版本" "当前 ${cur:-unknown}，上游 ${latest:-unknown}"
elif python3 "$VH_DIR/vh_rules.py" vercmp "$cur" "$latest"; then
  emit S-01 P1 pass 1panel guided "Vaultwarden 版本" "$cur（上游 $latest）"
else
  emit S-01 P1 fail 1panel guided "Vaultwarden 版本" "$cur 落后于上游 $latest"
fi
