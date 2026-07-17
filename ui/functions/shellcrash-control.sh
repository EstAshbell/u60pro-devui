#!/bin/sh

# ShellCrash adapter for the U60 DevUI custom function page.
# SHELLCRASH_DIR is only an override for tests; devices use /etc/ShellCrash.
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

emit() {
    value=$(printf '%s' "$2" | tr '\r\n\t' '   ' | cut -c 1-180)
    printf '%s=%s\n' "$1" "$value"
}

api_get() {
    path=$1
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 2 -H "Authorization: Bearer $secret" \
            -H 'Content-Type: application/json' "http://127.0.0.1:$db_port$path" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 2 --header="Authorization: Bearer $secret" \
            --header='Content-Type: application/json' -O - \
            "http://127.0.0.1:$db_port$path" 2>/dev/null
    else
        return 1
    fi
}

format_bytes() {
    bytes=$1
    case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
    if [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        awk -v n="$bytes" 'BEGIN { printf "%.2f GB", n / 1073741824 }'
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        awk -v n="$bytes" 'BEGIN { printf "%.1f MB", n / 1048576 }'
    elif [ "$bytes" -ge 1024 ] 2>/dev/null; then
        awk -v n="$bytes" 'BEGIN { printf "%.1f KB", n / 1024 }'
    else
        printf '%s B' "$bytes"
    fi
}

status() {
    installed=0
    running=0
    api_ok=0
    core='-'
    mode='-'
    node='-'
    upload='-'
    download='-'

    [ -f "$SC_DIR/start.sh" ] && installed=1
    pidof CrashCore >/dev/null 2>&1 && running=1

    crashcore=$(cfg_get crashcore)
    case "$crashcore" in
        meta) core='Mihomo' ;;
        singbox) core='Sing-box' ;;
        singboxr) core='Sing-box R' ;;
        clash|clashpre) core='Clash' ;;
        '') core='-' ;;
        *) core=$crashcore ;;
    esac
    mode=$(cfg_get redir_mod)
    [ -n "$mode" ] || mode=$(cfg_get firewall_area)
    [ -n "$mode" ] || mode='-'
    db_port=$(cfg_get db_port)
    secret=$(cfg_get secret)
    [ -n "$db_port" ] || db_port=9999

    if [ "$running" -eq 1 ]; then
        proxies=$(api_get /proxies)
        if [ -n "$proxies" ]; then
            api_ok=1
            selector_lines=$(printf '%s' "$proxies" | sed 's/:{/\
{/g' | grep -aE '"type"[[:space:]]*:[[:space:]]*"Selector"')
            selected=$(printf '%s\n' "$selector_lines" | grep -aE '"name"[[:space:]]*:[[:space:]]*"GLOBAL"' | head -n 1)
            [ -n "$selected" ] || selected=$(printf '%s\n' "$selector_lines" | head -n 1)
            current=$(printf '%s' "$selected" | sed -n 's/.*"now"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
            [ -n "$current" ] && node=$current
        fi

        connections=$(api_get /connections)
        if [ -n "$connections" ]; then
            up=$(printf '%s' "$connections" | grep -aoE '"uploadTotal"[[:space:]]*:[[:space:]]*[0-9]+' | head -n 1 | grep -oE '[0-9]+$')
            down=$(printf '%s' "$connections" | grep -aoE '"downloadTotal"[[:space:]]*:[[:space:]]*[0-9]+' | head -n 1 | grep -oE '[0-9]+$')
            [ -n "$up" ] && upload=$(format_bytes "$up")
            [ -n "$down" ] && download=$(format_bytes "$down")
        fi
    fi

    emit INSTALLED "$installed"
    emit RUNNING "$running"
    emit API "$api_ok"
    emit CORE "$core"
    emit MODE "$mode"
    emit NODE "$node"
    emit UPLOAD "$upload"
    emit DOWNLOAD "$download"
}

case "${1:-status}" in
    status)
        status
        ;;
    start|stop|restart)
        [ -f "$SC_DIR/start.sh" ] || {
            echo "ShellCrash is not installed at $SC_DIR" >&2
            exit 1
        }
        exec /bin/sh "$SC_DIR/start.sh" "$1"
        ;;
    *)
        echo 'usage: shellcrash-control.sh {status|start|stop|restart}' >&2
        exit 2
        ;;
esac
