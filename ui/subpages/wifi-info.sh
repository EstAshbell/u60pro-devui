#!/bin/sh
# Read only the two main AP profiles. Output is length-framed for an anonymous
# DevUI pipe; never redirect this private payload to a diagnostic log/file.
set -u
export LC_ALL=C
UCI_BIN=${DEVUI_WIFI_UCI_BIN:-/sbin/uci}

read_field() {
    # A non-newline suffix preserves trailing SSID/key newlines through command
    # substitution. Remove exactly the single newline printed by uci itself.
    result=$("$UCI_BIN" -q get "$2" 2>/dev/null; printf ':%s' "$?")
    rc=${result##*:}
    value=${result%:*}
    if [ "$rc" = 0 ] && [ -n "$value" ]; then value=${value%?}; fi
    printf 'WIFI_CRED %s %s %s\n' "$1" "$rc" "${#value}"
    printf '%s' "$value"
}

read_field 24S wireless.main_2g.ssid
read_field 24K wireless.main_2g.key
read_field 24E wireless.main_2g.encryption
read_field 5S wireless.main_5g.ssid
read_field 5K wireless.main_5g.key
read_field 5E wireless.main_5g.encryption
