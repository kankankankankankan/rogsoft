#!/bin/sh
# Recover the Tailscale Linux data plane from the 1.92.x-1.94.2
# wgcfg.Reconfig/ParseEndpoint startup race (tailscale#18270, #18918).

TS_BIN=${TS_BIN:-/koolshare/bin/tailscale}
IP_BIN=${IP_BIN:-ip}
DBUS_BIN=${DBUS_BIN:-dbus}
LOGGER_BIN=${LOGGER_BIN:-logger}
SLEEP_BIN=${SLEEP_BIN:-sleep}
TS_RECOVER_DELAY=${TS_RECOVER_DELAY:-60}
TS_RECOVER_LOCK=${TS_RECOVER_LOCK:-/tmp/tailscale-recover.lock}
TS_RECOVER_STATUS=${TS_RECOVER_STATUS:-/tmp/upload/tailscale_recover_status.txt}
TAG=tailscale-recover

log_msg() {
    "$LOGGER_BIN" -t "$TAG" "$*"
}

write_status() {
    state=$1
    action=$2
    ipv4=$($TS_BIN ip -4 2>/dev/null | head -n 1)
    [ -n "$ipv4" ] || ipv4="未分配"
    {
        echo "状态：$state"
        echo "检查时间：$(date '+%F %T')"
        echo "控制面 IPv4：$ipv4"
        echo "处理：$action"
    } >"$TS_RECOVER_STATUS"
}

dataplane_healthy() {
    "$IP_BIN" -4 addr show dev tailscale0 2>/dev/null |
        grep -q 'inet 100\.' || return 1
    "$IP_BIN" -4 route show table 52 2>/dev/null |
        grep -q 'dev tailscale0' || return 1
    return 0
}

lan_cidr() {
    "$IP_BIN" -4 route show dev br0 2>/dev/null |
        awk '$1 ~ /^[0-9]+\./ && $1 ~ /\// { print $1; exit }'
}

recover_worker() {
    trap 'rmdir "$TS_RECOVER_LOCK" 2>/dev/null' 0 1 2 15

    "$SLEEP_BIN" "$TS_RECOVER_DELAY"

    if dataplane_healthy; then
        write_status "正常" "无需恢复"
        log_msg "tailscale0 address and table 52 are healthy"
        return 0
    fi

    write_status "异常" "正在执行 tailscale down/up"
    log_msg "data plane missing; applying preference-preserving down/up recovery"

    "$TS_BIN" down
    down_rc=$?
    "$SLEEP_BIN" 3
    if [ "$down_rc" -ne 0 ]; then
        write_status "恢复失败" "tailscale down 返回 ${down_rc}"
        log_msg "recovery failed: tailscale down rc=$down_rc"
        return 1
    fi

    accept_routes=false
    [ "$($DBUS_BIN get tailscale_accept_routes 2>/dev/null)" = "1" ] &&
        accept_routes=true

    advertise_routes=$($DBUS_BIN get tailscale_advertise_routes 2>/dev/null)
    advertise_exit=$($DBUS_BIN get tailscale_exit_node 2>/dev/null)

    set -- up \
        --accept-routes="$accept_routes" \
        --accept-dns=false \
        --snat-subnet-routes=false \
        --stateful-filtering=false \
        --netfilter-mode=on \
        --auto-update=true

    if [ "$advertise_routes" = "1" ]; then
        cidr=$(lan_cidr)
        if [ -z "$cidr" ]; then
            write_status "恢复失败" "无法获取 br0 LAN 网段"
            log_msg "recovery failed: unable to determine br0 LAN CIDR"
            return 1
        fi
        set -- "$@" --advertise-routes="$cidr"
    else
        set -- "$@" --advertise-routes=
    fi

    if [ "$advertise_exit" = "1" ]; then
        set -- "$@" --advertise-exit-node=true
    else
        set -- "$@" --advertise-exit-node=false
    fi

    "$TS_BIN" "$@"
    up_rc=$?
    "$SLEEP_BIN" 10

    if [ "$up_rc" -eq 0 ] && dataplane_healthy; then
        write_status "已恢复" "已完成 tailscale down/up"
        log_msg "data plane restored"
        return 0
    fi

    write_status "恢复失败" "tailscale up 返回 ${up_rc}，数据面仍异常"
    log_msg "recovery failed: tailscale up rc=$up_rc or data plane still missing"
    return 1
}

case "${1:-start}" in
    start|recover)
        mkdir "$TS_RECOVER_LOCK" 2>/dev/null || exit 0
        if [ "${TS_RECOVER_FOREGROUND:-0}" = "1" ]; then
            recover_worker
            exit $?
        fi
        recover_worker >/dev/null 2>&1 &
        ;;
    status)
        if [ -f "$TS_RECOVER_STATUS" ]; then
            cat "$TS_RECOVER_STATUS"
        else
            echo "状态：尚未检查"
        fi
        ;;
    *)
        exit 0
        ;;
esac

exit 0
