#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d /tmp/u60-wifi-test.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT INT TERM
export DEVUI_WIFI_SYS_NET="$TEST_DIR/net"
export WIFI_TEST_LOG="$TEST_DIR/commands"
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/real" "$DEVUI_WIFI_SYS_NET/wlan0" "$DEVUI_WIFI_SYS_NET/wlan2"
export PATH="$TEST_DIR/bin:$PATH"
export DEVUI_WIFI_IFCONFIG="$TEST_DIR/real/ifconfig"
export DEVUI_WIFI_HOSTAPD_DIR="$TEST_DIR/vendor-hostapd"
CONTROL="$ROOT/ui/subpages/wifi-control.sh"

cat >"$DEVUI_WIFI_IFCONFIG" <<'EOF'
#!/bin/sh
echo "ifconfig $*" >>"$WIFI_TEST_LOG"
[ "${FAKE_IFCONFIG_FAIL:-0}" != 1 ] || exit 1
[ "${FAKE_IFCONFIG_NOOP:-0}" != 1 ] || exit 0
case "$2" in up) flags=0x1003 ;; down) flags=0x1002 ;; *) exit 1 ;; esac
echo "$flags" >"$DEVUI_WIFI_SYS_NET/$1/flags"
EOF
cat >"$TEST_DIR/bin/ifconfig" <<'EOF'
#!/bin/sh
echo 'unsafe PATH wrapper invoked' >>"$WIFI_TEST_LOG"
exit 99
EOF
cat >"$TEST_DIR/bin/hostapd_cli" <<'EOF'
#!/bin/sh
echo "hostapd_cli $*" >>"$WIFI_TEST_LOG"
if [ "${FAKE_CLI_FAIL:-0}" = 1 ]; then echo FAIL; else echo OK; fi
EOF
cat >"$TEST_DIR/bin/killall" <<'EOF'
#!/bin/sh
echo "killall $*" >>"$WIFI_TEST_LOG"
[ "${FAKE_HUP_FAIL:-0}" != 1 ] || exit 1
for iface in wlan0 wlan2; do echo 0x1003 >"$DEVUI_WIFI_SYS_NET/$iface/flags"; done
EOF
cat >"$TEST_DIR/bin/timeout" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF
cat >"$TEST_DIR/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TEST_DIR/bin/"* "$DEVUI_WIFI_IFCONFIG"

reset_state() {
    echo 0x1003 >"$DEVUI_WIFI_SYS_NET/wlan0/flags"
    echo 0x1003 >"$DEVUI_WIFI_SYS_NET/wlan2/flags"
    # A radio can have no carrier while the administrative switch remains on.
    echo down >"$DEVUI_WIFI_SYS_NET/wlan0/operstate"
    : >"$WIFI_TEST_LOG"
}
must_fail() {
    if "$@" >"$TEST_DIR/output" 2>&1; then echo "unexpected success: $*" >&2; exit 1; fi
}

reset_state
[ "$(sh "$CONTROL" status)" = "$(printf 'W0=up\nW2=up')" ]
sh "$CONTROL" set 24 down >"$TEST_DIR/output"
[ "$(cat "$DEVUI_WIFI_SYS_NET/wlan0/flags")" = 0x1002 ]
[ "$(cat "$DEVUI_WIFI_SYS_NET/wlan2/flags")" = 0x1003 ]
! grep -q 'wlan2' "$WIFI_TEST_LOG"
# Repeating a set is idempotent; it must never become a flip.
sh "$CONTROL" set 24 down >"$TEST_DIR/output"
[ "$(cat "$DEVUI_WIFI_SYS_NET/wlan0/flags")" = 0x1002 ]
sh "$CONTROL" set 24 up >"$TEST_DIR/output"
grep -Fq "hostapd_cli -p $DEVUI_WIFI_HOSTAPD_DIR -i wlan0 enable" "$WIFI_TEST_LOG"
! grep -q 'unsafe PATH wrapper' "$WIFI_TEST_LOG"

reset_state
sh "$CONTROL" set all down >"$TEST_DIR/output"
[ "$(sh "$CONTROL" status)" = "$(printf 'W0=down\nW2=down')" ]
sh "$CONTROL" set 5 up >"$TEST_DIR/output"
[ "$(sh "$CONTROL" status)" = "$(printf 'W0=down\nW2=up')" ]
sh "$CONTROL" set all up >"$TEST_DIR/output"
[ "$(sh "$CONTROL" status)" = "$(printf 'W0=up\nW2=up')" ]
sh "$CONTROL" set all down >"$TEST_DIR/output"
FAKE_CLI_FAIL=1 sh "$CONTROL" set 24 up >"$TEST_DIR/output"
grep -q 'killall -HUP hostapd' "$WIFI_TEST_LOG"
# A global HUP must not re-enable the other disabled band.
[ "$(sh "$CONTROL" status)" = "$(printf 'W0=up\nW2=down')" ]

reset_state
must_fail env FAKE_IFCONFIG_FAIL=1 sh "$CONTROL" set 24 down
must_fail env FAKE_IFCONFIG_NOOP=1 sh "$CONTROL" set 24 down
must_fail env FAKE_CLI_FAIL=1 FAKE_HUP_FAIL=1 sh "$CONTROL" set 24 up
must_fail sh "$CONTROL" set arbitrary down
must_fail sh "$CONTROL" set 24 arbitrary
reset_state
rm "$DEVUI_WIFI_SYS_NET/wlan2/flags"
must_fail sh "$CONTROL" set all down
# Prevalidation prevents a partial change when one requested interface is absent.
[ ! -s "$WIFI_TEST_LOG" ]
[ "$(cat "$DEVUI_WIFI_SYS_NET/wlan0/flags")" = 0x1003 ]
[ "$(sh "$CONTROL" status)" = "$(printf 'W0=up\nW2=unknown')" ]

echo 'wifi control tests passed'
