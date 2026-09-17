#!/bin/sh
set -eu

KS_ROOT=${KS_ROOT:-/koolshare}
SKIP_RECOVERY=${SKIP_RECOVERY:-0}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE="$SCRIPT_DIR/tailscale"
BACKUP="$KS_ROOT/configs/tailscale/recovery-patch-backup"

if [ ! -x "$KS_ROOT/scripts/tailscale_config" ]; then
    echo "错误：未发现已安装的 Koolshare Tailscale 插件。" >&2
    exit 1
fi

if [ ! -f "$KS_ROOT/webs/Module_tailscale.asp" ]; then
    echo "错误：未发现 Tailscale 插件面板。" >&2
    exit 1
fi

if ! grep -q 'get_tcnets_status' "$KS_ROOT/webs/Module_tailscale.asp"; then
    echo "错误：面板版本与补丁基线不匹配，拒绝覆盖。" >&2
    exit 1
fi

mkdir -p "$BACKUP"
if [ ! -f "$BACKUP/Module_tailscale.asp" ]; then
    cp -p "$KS_ROOT/webs/Module_tailscale.asp" "$BACKUP/Module_tailscale.asp"
fi

cp -p "$SOURCE/scripts-hnd/tailscale_recover.sh" \
    "$KS_ROOT/scripts/tailscale_recover.sh"
cp -p "$SOURCE/init.d/S97tailscale-recover.sh" \
    "$KS_ROOT/init.d/S97tailscale-recover.sh"
cp -p "$SOURCE/webs/Module_tailscale.asp" \
    "$KS_ROOT/webs/Module_tailscale.asp"

chmod 755 \
    "$KS_ROOT/scripts/tailscale_recover.sh" \
    "$KS_ROOT/init.d/S97tailscale-recover.sh"

if [ "$SKIP_RECOVERY" != "1" ]; then
    "$KS_ROOT/scripts/tailscale_recover.sh" start
fi

echo "补丁安装完成。"
echo "原面板备份：$BACKUP/Module_tailscale.asp"
echo "自愈脚本：$KS_ROOT/scripts/tailscale_recover.sh"
echo "WAN 钩子：$KS_ROOT/init.d/S97tailscale-recover.sh"
