#!/usr/bin/env bash
# 数据与备份
# D-01：以 vbm status 退出码为准；输出中的「超期」或非零计数的「失败」也判失败（failed: 0 不算）
if command -v vbm >/dev/null 2>&1; then
  vbm_rc=0
  vbm_st=$(vbm status 2>&1) || vbm_rc=$?
  vbm_fail_lines=$(grep -Ei '失败|fail' <<<"$vbm_st" || true)
  if ((vbm_rc != 0)); then
    emit D-01 P0 fail vhm report "备份 (vbm)" "vbm status 退出码 $vbm_rc"
  elif grep -Eqi '超期|overdue' <<<"$vbm_st"; then
    emit D-01 P0 fail vhm report "备份 (vbm)" "vbm status 报告备份超期"
  elif [[ -n "$vbm_fail_lines" ]] && grep -Evq '[:：=][[:space:]]*0([^0-9]|$)' <<<"$vbm_fail_lines"; then
    emit D-01 P0 fail vhm report "备份 (vbm)" "vbm status 报告备份失败"
  else
    emit D-01 P0 pass vhm report "备份 (vbm)" "vbm 已安装且状态正常"
  fi
else
  emit D-01 P0 fail vhm report "备份 (vbm)" "未安装 vaultwarden-1panel-backup-manager"
fi

# D-02：敏感路径（含 -wal/-shm、rsa_key*、attachments、sends）对其他用户不应有任何权限
loose=()
checked=0
while IFS= read -r p; do
  m=$(stat -c '%a' "$p") || continue
  checked=$((checked + 1))
  (((8#$m & 8#007) != 0)) && loose+=("$p:$m")
done < <(vw_sensitive_paths)
if ((${#loose[@]})); then
  emit D-02 P1 fail host auto "数据目录权限" "${loose[*]}"
else
  emit D-02 P1 pass host auto "数据目录权限" "其他用户无权限（检查 $checked 项）"
fi

src=$(df --output=source "$VW_DATA_DIR" 2>/dev/null | tail -n1)
if lsblk -no TYPE "$src" 2>/dev/null | grep -q crypt || [[ "$src" == /dev/mapper/*crypt* ]]; then
  emit D-03 P2 pass host report "磁盘加密" "$src"
else
  emit D-03 P2 warn host report "磁盘加密" "$src 未检测到 LUKS"
fi
:
