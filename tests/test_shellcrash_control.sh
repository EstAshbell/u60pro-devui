#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP_ROOT=$(mktemp -d /tmp/u60-shellcrash-test.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

SC_DIR="$TMP_ROOT/ShellCrash"
FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$SC_DIR/configs" "$FAKE_BIN"

cat >"$SC_DIR/configs/ShellCrash.cfg" <<'EOF'
crashcore=meta
redir_mod=Tproxy
db_port=9999
secret='test secret'
EOF

cat >"$SC_DIR/start.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >"$SHELLCRASH_DIR/action.log"
EOF

cat >"$FAKE_BIN/pidof" <<'EOF'
#!/bin/sh
[ "${1:-}" = CrashCore ] && { echo 1234; exit 0; }
exit 1
EOF

cat >"$FAKE_BIN/curl" <<'EOF'
#!/bin/sh
[ "${FAKE_API_FAIL:-0}" = 1 ] && exit 1
case "$*" in
    */proxies*)
        printf '%s\n' '{"proxies":{"Auto":{"type":"Selector","name":"Auto","now":"Fallback"},"GLOBAL":{"type":"Selector","name":"GLOBAL","now":"Node & <safe>"}}}'
        ;;
    */connections*)
        printf '%s\n' '{"downloadTotal":2097152,"uploadTotal":1536,"connections":[]}'
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$SC_DIR/start.sh" "$FAKE_BIN/pidof" "$FAKE_BIN/curl"

STATUS=$(PATH="$FAKE_BIN:$PATH" SHELLCRASH_DIR="$SC_DIR" \
    /bin/sh "$ROOT/ui/functions/shellcrash-control.sh" status)

assert_line() {
    printf '%s\n' "$STATUS" | grep -Fqx "$1" || {
        printf 'missing status line: %s\n%s\n' "$1" "$STATUS" >&2
        exit 1
    }
}

assert_line 'INSTALLED=1'
assert_line 'RUNNING=1'
assert_line 'API=1'
assert_line 'CORE=Mihomo'
assert_line 'MODE=Tproxy'
assert_line 'NODE=Node & <safe>'
assert_line 'UPLOAD=1.5 KB'
assert_line 'DOWNLOAD=2.0 MB'

STATUS=$(PATH="$FAKE_BIN:$PATH" FAKE_API_FAIL=1 SHELLCRASH_DIR="$SC_DIR" \
    /bin/sh "$ROOT/ui/functions/shellcrash-control.sh" status)
assert_line 'RUNNING=1'
assert_line 'API=0'
assert_line 'NODE=-'

cat >"$FAKE_BIN/pidof" <<'EOF'
#!/bin/sh
exit 1
EOF
STATUS=$(PATH="$FAKE_BIN:$PATH" SHELLCRASH_DIR="$TMP_ROOT/missing" \
    /bin/sh "$ROOT/ui/functions/shellcrash-control.sh" status)
assert_line 'INSTALLED=0'
assert_line 'RUNNING=0'
assert_line 'API=0'

PATH="$FAKE_BIN:$PATH" SHELLCRASH_DIR="$SC_DIR" \
    /bin/sh "$ROOT/ui/functions/shellcrash-control.sh" restart
[ "$(cat "$SC_DIR/action.log")" = restart ]

if PATH="$FAKE_BIN:$PATH" SHELLCRASH_DIR="$SC_DIR" \
    /bin/sh "$ROOT/ui/functions/shellcrash-control.sh" arbitrary 2>/dev/null; then
    echo 'arbitrary action unexpectedly succeeded' >&2
    exit 1
fi

echo 'shellcrash control tests passed'
