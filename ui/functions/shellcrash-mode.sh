#!/bin/sh

# Read/switch the live Clash-compatible proxy mode used by ShellCrash.
SC_DIR=${SHELLCRASH_DIR:-/etc/ShellCrash}
SC_CFG="$SC_DIR/configs/ShellCrash.cfg"

cfg_get() {
    [ -f "$SC_CFG" ] || return 0
    value=$(sed -n "s/^$1=//p" "$SC_CFG" 2>/dev/null | head -n 1)
    case "$value" in
        \"*\") value=${value#\"}; value=${value%\"} ;;
        \'*\') value=${value#\'}; value=${value%\'} ;;
    esac
    printf '%s' "$value"
}

yaml_get() {
    [ -f "$SC_DIR/config.yaml" ] || return 0
    value=$(sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" "$SC_DIR/config.yaml" 2>/dev/null | head -n 1)
    value=${value%%#*}
    value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case "$value" in
        \"*\") value=${value#\"}; value=${value%\"} ;;
        \'*\') value=${value#\'}; value=${value%\'} ;;
    esac
    printf '%s' "$value"
}

db_port=$(cfg_get db_port)
secret=$(cfg_get secret)
if [ -z "$db_port" ]; then
    controller=$(yaml_get external-controller)
    db_port=${controller##*:}
fi
[ -n "$secret" ] || secret=$(yaml_get secret)
case "$db_port" in ''|*[!0-9]*) db_port=9999 ;; esac
api="http://127.0.0.1:$db_port/configs"

api_get() {
    if [ -n "$secret" ]; then
        curl -fsS --max-time 1 -H "Authorization: Bearer $secret" "$api" 2>/dev/null
    else
        curl -fsS --max-time 1 "$api" 2>/dev/null
    fi
}

api_set() {
    body=$1
    if [ -n "$secret" ]; then
        curl -fsS --max-time 3 -X PATCH -H "Authorization: Bearer $secret" \
            -H 'Content-Type: application/json' --data-binary "$body" "$api" >/dev/null 2>&1
    else
        curl -fsS --max-time 3 -X PATCH -H 'Content-Type: application/json' \
            --data-binary "$body" "$api" >/dev/null 2>&1
    fi
}

case "${1:-get}" in
    get)
        json=$(api_get) || exit 1
        mode=$(printf '%s' "$json" | sed -n 's/.*"mode"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 | tr 'A-Z' 'a-z')
        case "$mode" in global|rule|direct) printf 'MODE=%s\n' "$mode" ;; *) exit 1 ;; esac
        ;;
    set)
        case "${2:-}" in
            global|rule|direct) mode=$2 ;;
            *) echo 'mode must be global, rule, or direct' >&2; exit 2 ;;
        esac
        api_set "{\"mode\":\"$mode\"}"
        ;;
    *)
        echo 'usage: shellcrash-mode.sh {get|set global|set rule|set direct}' >&2
        exit 2
        ;;
esac
