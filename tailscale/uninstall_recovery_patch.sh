#!/bin/sh
set -eu

KS_ROOT=${KS_ROOT:-/koolshare}
BACKUP="$KS_ROOT/configs/tailscale/recovery-patch-backup"

rm -f "$KS_ROOT/scripts/tailscale_recover.sh"
rm -f "$KS_ROOT/init.d/S97tailscale-recover.sh"
rm -f /tmp/upload/tailscale_recover_status.txt
rm -rf /tmp/tailscale-recover.lock

if [ -f "$BACKUP/Module_tailscale.asp" ]; then
    cp -p "$BACKUP/Module_tailscale.asp" \
        "$KS_ROOT/webs/Module_tailscale.asp"
    echo "已恢复原始 Tailscale 面板。"
else
    echo "警告：未找到原始面板备份，仅删除自愈文件。" >&2
fi

echo "补丁已卸载；Tailscale 身份和配置未改动。"
