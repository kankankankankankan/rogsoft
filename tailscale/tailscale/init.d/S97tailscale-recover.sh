#!/bin/sh

case "$1" in
    start)
        /koolshare/scripts/tailscale_recover.sh start
        ;;
esac

exit 0
