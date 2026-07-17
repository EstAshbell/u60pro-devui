#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP_ROOT=$(mktemp -d /tmp/u60-shellcrash-mode-test.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM
SC_DIR="$TMP_ROOT/ShellCrash"
FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$SC_DIR/configs" "$FAKE_BIN"

cat >"$SC_DIR/configs/ShellCrash.cfg" <<'EOF'
db_port=9999
secret='test secret'
EOF

cat >"$FAKE_BIN/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$SHELLCRASH_DIR/curl.args"
case "$*" in
    *'-X PATCH'*) exit 0 ;;
    *) printf '%s\n' '{"port":7890,"mode":"Rule"}' ;;
esac
EOF
chmod +x "$FAKE_BIN/curl"

OUT=$(PATH="$FAKE_BIN:$PATH" SHELLCRASH_DIR="$SC_DIR" \
    /bin/sh "$ROOT/ui/functions/shellcrash-mode.sh" get)
[ "$OUT" = 'MODE=rule' ]
grep -Fq 'Authorization: Bearer test secret' "$SC_DIR/curl.args"
grep -Fq 'http://127.0.0.1:9999/configs' "$SC_DIR/curl.args"

for mode in global rule direct; do
    PATH="$FAKE_BIN:$PATH" SHELLCRASH_DIR="$SC_DIR" \
        /bin/sh "$ROOT/ui/functions/shellcrash-mode.sh" set "$mode"
    grep -Fq -- '-X PATCH' "$SC_DIR/curl.args"
    grep -Fq -- "{\"mode\":\"$mode\"}" "$SC_DIR/curl.args"
done

if PATH="$FAKE_BIN:$PATH" SHELLCRASH_DIR="$SC_DIR" \
    /bin/sh "$ROOT/ui/functions/shellcrash-mode.sh" set arbitrary 2>/dev/null; then
    echo 'arbitrary mode unexpectedly succeeded' >&2
    exit 1
fi

echo 'shellcrash mode tests passed'
