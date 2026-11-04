#!/bin/sh
# Runtime AP controls for the U60 Pro vendor firmware. Do not use wifi reload or
# zwrt_wlan reload here: these firmware paths can tear down the radios.
# Interface flags describe the administrative switch; operstate describes the
# link and may be down/unknown even when the AP is enabled.
set -u

SYS_NET=${DEVUI_WIFI_SYS_NET:-/sys/class/net}

net_state() {
    flags=$(cat "$SYS_NET/$1/flags" 2>/dev/null) || { echo unknown; return; }
    case "$flags" in 0x*) digits=${flags#0x} ;; *) echo unknown; return ;; esac
    case "$digits" in ''|*[!0-9a-fA-F]*) echo unknown; return ;; esac
    if [ "$((flags & 1))" -eq 1 ]; then echo up; else echo down; fi
}

status() {
    printf 'W0=%s\nW2=%s\n' "$(net_state wlan0)" "$(net_state wlan2)"
}

cli() {
    command -v hostapd_cli >/dev/null 2>&1 || return 1
    ctrl_dir=${DEVUI_WIFI_HOSTAPD_DIR:-}
    if [ -z "$ctrl_dir" ]; then
        for candidate in /data/vendor/wifi/hostapd /var/run/hostapd /run/hostapd; do
            if [ -S "$candidate/$1" ]; then ctrl_dir=$candidate; break; fi
        done
    fi
    set -- -i "$1" "$2"
    [ -z "$ctrl_dir" ] || set -- -p "$ctrl_dir" "$@"
    cli_rc=0
    if command -v timeout >/dev/null 2>&1; then
        reply=$(timeout 2 hostapd_cli "$@" 2>&1) || cli_rc=$?
    else
        reply=$(hostapd_cli "$@" 2>&1) || cli_rc=$?
    fi
    printf '%s\n' "$reply"
    [ "$cli_rc" -eq 0 ] && printf '%s\n' "$reply" | grep -q '^OK$'
}

case "${1:-}" in
    status) [ "$#" -eq 1 ] || exit 2; status; exit 0 ;;
    set) [ "$#" -eq 3 ] || exit 2 ;;
    *) echo 'usage: wifi-control.sh status | set 24|5|all up|down' >&2; exit 2 ;;
esac
case "$2" in 24) ifaces=wlan0 ;; 5) ifaces=wlan2 ;; all) ifaces='wlan0 wlan2' ;; *) exit 2 ;; esac
case "$3" in up|down) target=$3 ;; *) exit 2 ;; esac
# Third-party desktops sometimes prepend a bin/ifconfig shim that turns an
# idempotent set into a toggle. Bypass PATH and use the firmware binary.
ifconfig_bin=${DEVUI_WIFI_IFCONFIG:-}
if [ -z "$ifconfig_bin" ]; then
    for candidate in /sbin/ifconfig /usr/sbin/ifconfig /bin/ifconfig; do
        if [ -x "$candidate" ]; then ifconfig_bin=$candidate; break; fi
    done
fi
[ -n "$ifconfig_bin" ] && [ -x "$ifconfig_bin" ] || { echo 'firmware ifconfig not found' >&2; exit 1; }

# Validate the entire request before changing either band.
for iface in $ifaces; do
    if [ "$(net_state "$iface")" = unknown ]; then
        echo "unreadable interface: $iface" >&2
        exit 1
    fi
done

printf 'action=%s ifaces=%s\n' "$target" "$ifaces"
cli_ok=1
for iface in $ifaces; do
    # Reinstall WPA state when resuming a radio instead of only raising netdev.
    cli "$iface" disable || true
    "$ifconfig_bin" "$iface" "$target" || { status; exit 1; }
done
if [ "$target" = up ]; then
    sleep 1
    for iface in $ifaces; do cli "$iface" enable || cli_ok=0; done
    if [ "$cli_ok" != 1 ]; then
        # Older vendor images expose no hostapd control socket. Preserve any
        # other band that was deliberately disabled before a daemon HUP.
        other_down=
        for iface in wlan0 wlan2; do
            case " $ifaces " in *" $iface "*) continue ;; esac
            [ "$(net_state "$iface")" != down ] || other_down="$other_down $iface"
        done
        echo hostapd-hup-fallback
        killall -HUP hostapd 2>/dev/null || killall -HUP wpad 2>/dev/null || { status; exit 1; }
        sleep 1
        for iface in $other_down; do "$ifconfig_bin" "$iface" down || { status; exit 1; }; done
    fi
fi

# A successful shell launch is not an applied switch. Check the actual netdevs
# after the driver has had time to settle and return a nonzero terminal result.
attempt=0
while [ "$attempt" -lt 4 ]; do
    matched=1
    for iface in $ifaces; do [ "$(net_state "$iface")" = "$target" ] || matched=0; done
    if [ "$matched" = 1 ]; then status; exit 0; fi
    attempt=$((attempt + 1))
    sleep 1
done
echo 'interface state did not match request' >&2
status
exit 1
