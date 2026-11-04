#!/bin/sh
# Ashbell U60 Pro desktop manager. Run on the OpenWrt device, as root.
# SPDX-License-Identifier: MIT
set -eu
umask 077

SOURCE=${ASHBELL_RELEASE_URL:-https://github.com/EstAshbell/u60pro-devui/releases/latest/download}
# A filesystem prefix is accepted only for the isolated installer tests.
ROOT=${ASHBELL_TEST_ROOT:-}
if [ -n "$ROOT" ]; then
    [ "${ASHBELL_TEST_MODE:-0}" = 1 ] || { echo '测试目录需要 ASHBELL_TEST_MODE=1' >&2; exit 2; }
    case "$ROOT" in /tmp/*|/private/tmp/*) ;; *) echo '测试目录必须位于 /tmp' >&2; exit 2 ;; esac
fi
DEVUI=$ROOT/data/plugins/u60pro-devui
DATAD=$ROOT/data/plugins/zwrt-datad
STATE=$ROOT/data/plugins/.ashbell-devui
RC=$ROOT/etc/rc.local
VENDOR=$ROOT/etc/init.d/zte_topsw_devui
BOOT=$ROOT/data/plugins/ufi_tools_boot.sh
UFI_BOOT=$ROOT/data/ufi-tools/sdcard/ufi_tools_boot.sh
STAGE=
TXN=
LOCKED=0
BOOT_TXN=
ARCHIVE_TXN=
ARCHIVE_SOURCE=
HOOK='[ -x /data/plugins/u60pro-devui/start.sh ] && sh /data/plugins/u60pro-devui/start.sh legacy >/tmp/u60pro-boot.log 2>&1 & # ashbell_devui'
ASSETS='version.json u60pro-devui-aarch64 zwrt-datad-aarch64 ui.tar.gz start.sh ashbell-devui.sh LICENSE NOTICE.md'
DESKTOP_HOOK_RE='ashbell_devui|/data/plugins/u60pro-devui/(start(-devui)?\.sh|u60pro-devui)([[:space:];&]|$)|/etc/init.d/u60pro-devui([[:space:];&]|$)|/data/u60pro/start\.sh|#[[:space:]]*u60pro_devui(_devui)?[[:space:]]*$'
BACKEND_HOOK_RE='u60pro_devui_datad|/data/plugins/zwrt-datad/(start(-datad)?\.sh|zwrt-datad)([[:space:];&]|$)|/etc/init.d/(zwrt-datad|u60-datad)([[:space:];&]|$)'

say() { printf '%s\n' "$*"; }
fail() { say "错误：$*" >&2; exit 1; }
service() { [ -n "$ROOT" ] || { [ ! -x "$1" ] || "$@" >/dev/null 2>&1 || true; }; }
legacy_worker_pids() {
    [ -z "$ROOT" ] || return 0
    for proc in /proc/[0-9]*/cmdline; do
        [ -r "$proc" ] || continue
        if tr '\000' '\n' <"$proc" 2>/dev/null | awk '
            NR<=3 && /^\/data\/plugins\/u60pro-devui\/(screen-[A-Za-z0-9_-]+\.sh|bin\/ifconfig|start-devui\.sh)$/ {found=1}
            END {exit found ? 0 : 1}
        '; then
            basename "$(dirname "$proc")"
        elif [ "$(readlink "$(dirname "$proc")/cwd" 2>/dev/null || true)" = "$DEVUI" ] &&
             tr '\000' '\n' <"$proc" 2>/dev/null | awk '
                 NR<=3 && /^(\.\/)?(screen-[A-Za-z0-9_-]+\.sh|bin\/ifconfig|start-devui\.sh)$/ {found=1}
                 END {exit found ? 0 : 1}
             '; then
            basename "$(dirname "$proc")"
        fi
    done
}

stop_legacy_workers() {
    [ -z "$ROOT" ] || return 0
    for helper in screen-traffic-stats.sh screen-wifi-key.sh screen-neighbor.sh screen-cell-page.sh; do
        [ ! -x "$DEVUI/$helper" ] || sh "$DEVUI/$helper" stop >/dev/null 2>&1 || true
    done
    # Stop orphan wrappers too, checking exact script arguments rather than
    # matching shell command text or killing an unrelated shell process.
    for old_pid in $(legacy_worker_pids); do kill "$old_pid" >/dev/null 2>&1 || true; done
    old_pids=$(legacy_worker_pids)
    [ -z "$old_pids" ] || sleep 1
    for old_pid in $(legacy_worker_pids); do kill -9 "$old_pid" >/dev/null 2>&1 || true; done
}
stop_desktop() {
    [ -z "$ROOT" ] || return 0
    stop_legacy_workers
    for name in u60pro-devui zwrt-datad u60-datad; do
        service "/etc/init.d/$name" stop
        killall "$name" >/dev/null 2>&1 || true
    done
    remaining=5
    while [ "$remaining" -gt 0 ]; do
        active=0
        for name in u60pro-devui zwrt-datad u60-datad; do
            pidof "$name" >/dev/null 2>&1 && active=1 || true
        done
        [ "$active" = 1 ] || break
        sleep 1; remaining=$((remaining - 1))
    done
    for name in u60pro-devui zwrt-datad u60-datad; do killall -9 "$name" >/dev/null 2>&1 || true; done
}
start_saved() {
    [ -z "$ROOT" ] || return 0
    if [ ! -f "$DEVUI/.ashbell-owned" ] && [ -f "$DEVUI/start-devui.sh" ] && [ -x "$DEVUI/u60pro-devui" ]; then
        [ ! -f "$DATAD/start-datad.sh" ] || sh "$DATAD/start-datad.sh" >/dev/null 2>&1
        sh "$DEVUI/start-devui.sh" >/tmp/u60pro-boot.log 2>&1 &
    elif [ -f "$DEVUI/start.sh" ] && [ -x "$DEVUI/u60pro-devui" ]; then
        sh "$DEVUI/start.sh" legacy >/tmp/u60pro-boot.log 2>&1 &
    else
        service "$VENDOR" start
    fi
}
restore() {
    saved=$1
    [ -f "$saved/snapshot.done" ] || { say '备份不完整，未执行恢复。' >&2; return 1; }
    stop_desktop
    for item in devui datad; do
        case "$item" in devui) dest=$DEVUI ;; datad) dest=$DATAD ;; esac
        rm -rf "$dest"
        if [ -d "$saved/$item" ]; then cp -a "$saved/$item" "$dest" || return 1; fi
    done
    if [ -f "$saved/rc.local" ]; then cp -p "$saved/rc.local" "$RC" || return 1; else rm -f "$RC"; fi
    for name in u60pro-devui zwrt-datad u60-datad zte_topsw_devui; do
        rm -f "$ROOT"/etc/rc.d/S*"$name" "$ROOT"/etc/rc.d/K*"$name"
    done
    if [ -d "$saved/rc.d" ]; then cp -a "$saved/rc.d/." "$ROOT/etc/rc.d/" || return 1; fi
    for entry in boot ufi-boot; do
        case "$entry" in boot) dest=$BOOT ;; ufi-boot) dest=$UFI_BOOT ;; esac
        if [ -f "$saved/$entry" ]; then cp -p "$saved/$entry" "$dest" || return 1; fi
    done
    if [ -f "$saved/baseline" ]; then cp "$saved/baseline" "$STATE/baseline"; else rm -f "$STATE/baseline"; fi
    if [ -f "$saved/autostart" ]; then cp "$saved/autostart" "$STATE/autostart"; else rm -f "$STATE/autostart"; fi
    start_saved
}
cleanup() {
    result=$?
    trap - EXIT HUP INT TERM
    if [ -n "$TXN" ]; then
        say "操作未完成，恢复备份：$(basename "$TXN")" >&2
        if ! restore "$TXN"; then
            say "自动恢复失败；保留备份 ${TXN}，请通过 ADB 检查。" >&2
            result=1
        fi
    fi
    if [ -n "$BOOT_TXN" ]; then restore_boot_settings "$BOOT_TXN" || result=1; fi
    if [ -n "$ARCHIVE_TXN" ]; then
        while IFS= read -r relative; do
            [ ! -e "$ARCHIVE_TXN/devui/$relative" ] && [ ! -L "$ARCHIVE_TXN/devui/$relative" ] || {
                mkdir -p "$ARCHIVE_SOURCE/$(dirname "$relative")"
                mv "$ARCHIVE_TXN/devui/$relative" "$ARCHIVE_SOURCE/$relative" || result=1
            }
        done <"$ARCHIVE_TXN/moved-files"
    fi
    [ -z "$STAGE" ] || rm -rf "$STAGE"
    [ "$LOCKED" = 0 ] || rm -rf "$STATE/lock"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

require_device() {
    [ "$(id -u)" = 0 ] || [ -n "$ROOT" ] || fail '需要 root 权限。'
    if [ -z "$ROOT" ]; then
        [ "$(uname -m)" = aarch64 ] || fail '仅支持 aarch64 U60 Pro/OpenWrt，未更改系统。'
        [ -e /dev/dri/card0 ] && [ -x "$VENDOR" ] && command -v ubus >/dev/null 2>&1 || fail '未发现 U60 Pro DRM、原厂桌面或 ubus，未更改系统。'
    fi
    for cmd in tar sha256sum od awk sed grep cp mv mktemp; do command -v "$cmd" >/dev/null 2>&1 || fail "缺少工具 $cmd"; done
    mkdir -p "$STATE/backups" "$ROOT/etc/rc.d" "$ROOT/data/plugins"
    chmod 700 "$STATE" "$STATE/backups"
    if ! mkdir "$STATE/lock" 2>/dev/null; then
        oldpid=$(cat "$STATE/lock/pid" 2>/dev/null || true)
        case "$oldpid" in ''|*[!0-9]*) fail '管理锁无效，请检查是否还有管理任务运行。' ;; esac
        if kill -0 "$oldpid" 2>/dev/null; then fail '另一个管理任务正在运行。'; fi
        rm -rf "$STATE/lock"
        mkdir "$STATE/lock" || fail '不能获取管理锁。'
    fi
    LOCKED=1
    echo $$ >"$STATE/lock/pid"
    STAGE=$(mktemp -d "$STATE/staging.XXXXXX")
}

download() {
    url=$1 out=$2
    case "$url" in https://*) ;; *) fail '在线更新源必须使用 HTTPS。' ;; esac
    if command -v curl >/dev/null 2>&1; then
        curl -fL --connect-timeout 15 --max-time 180 --retry 2 --output "$out" "$url" || fail '下载失败；现有桌面未更改。请检查网络或使用离线安装包。'
    elif command -v wget >/dev/null 2>&1; then
        wget -T 180 -O "$out" "$url" || fail '下载失败；现有桌面未更改。请检查证书/网络或使用离线安装包。'
    else
        fail '需要 curl 或 wget 下载，也可传入离线安装包路径。'
    fi
}

# Only regular files and directories with simple relative names may be extracted.
# Reject links before extraction, including links pointing outside the destination.
check_tar() {
    archive=$1 list=$2
    tar -tzf "$archive" >"$list" 2>/dev/null || fail '压缩包损坏，或下载到的内容不是 gzip tar 包。'
    [ -s "$list" ] || fail '压缩包为空。'
    LC_ALL=C awk '
        /^\// || /(^|\/)\.\.?($|\/)/ || /[^A-Za-z0-9_.\/-]/ { bad=1 }
        { if (seen[$0]++) bad=1 }
        END { exit bad ? 1 : 0 }
    ' "$list" || fail '压缩包含不安全路径、重复条目或不支持的文件名。'
    tar -tvzf "$archive" >"$list.types" 2>/dev/null || fail '不能读取压缩包条目。'
    LC_ALL=C awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" { bad=1 } END { exit bad ? 1 : 0 }' "$list.types" || fail '压缩包不能包含符号链接、设备文件或硬链接。'
}

elf_ok() {
    [ "$(dd if="$1" bs=1 count=6 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 7f454c460201 ] &&
    [ "$(dd if="$1" bs=1 skip=18 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')" = b700 ] &&
    [ "$(wc -c <"$1" | tr -d ' ')" -ge 64 ]
}

validate_bundle() {
    archive=$1
    check_tar "$archive" "$STAGE/bundle.list"
    for name in $ASSETS SHA256SUMS; do
        grep -Fxq "$name" "$STAGE/bundle.list" || fail "安装包缺少 ${name}；请使用完整 Ashbell 包，不能只上传 ui.tar.gz。"
    done
    # The outer package has a fixed file set; unknown files are not executed.
    [ "$(wc -l <"$STAGE/bundle.list" | tr -d ' ')" = 9 ] || fail '安装包包含非标准顶层条目。'
    mkdir "$STAGE/bundle"
    tar -xzf "$archive" -C "$STAGE/bundle" || fail '解压安装包失败。'
    for name in $ASSETS; do
        grep -E "^[0-9a-fA-F]{64}  $name\$" "$STAGE/bundle/SHA256SUMS" >"$STAGE/checksum" || fail "缺少 $name 的 SHA256。"
        [ "$(wc -l <"$STAGE/checksum" | tr -d ' ')" = 1 ] || fail '校验清单包含重复项。'
        (cd "$STAGE/bundle" && sha256sum -c "$STAGE/checksum" >/dev/null 2>&1) || fail "$name 校验失败，未替换已安装桌面。"
    done
    elf_ok "$STAGE/bundle/u60pro-devui-aarch64" || fail '桌面二进制不是 AArch64 ELF。'
    elf_ok "$STAGE/bundle/zwrt-datad-aarch64" || fail 'datad 二进制不是 AArch64 ELF。'
    sh -n "$STAGE/bundle/start.sh" && sh -n "$STAGE/bundle/ashbell-devui.sh" || fail '启动/管理脚本语法错误。'
    # jsonfilter ships with OpenWrt; the host test uses Python to read the manifest.
    if command -v jsonfilter >/dev/null 2>&1; then
        schema=$(jsonfilter -i "$STAGE/bundle/version.json" -e '@.schema')
        devasset=$(jsonfilter -i "$STAGE/bundle/version.json" -e '@.devui.asset')
        datasset=$(jsonfilter -i "$STAGE/bundle/version.json" -e '@.datad.asset')
        uiasset=$(jsonfilter -i "$STAGE/bundle/version.json" -e '@.ui.asset')
        [ "$schema:$devasset:$datasset:$uiasset" = '1:u60pro-devui-aarch64:zwrt-datad-aarch64:ui.tar.gz' ] || fail '版本清单与安装资产不匹配。'
    elif [ -n "$ROOT" ]; then
        python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); assert v["schema"]==1; assert [v[k]["asset"] for k in ("devui","datad","ui")]==["u60pro-devui-aarch64","zwrt-datad-aarch64","ui.tar.gz"]' "$STAGE/bundle/version.json" || fail '版本清单无效。'
    else
        fail '缺少 jsonfilter，不能可靠核对版本清单。'
    fi
    check_tar "$STAGE/bundle/ui.tar.gz" "$STAGE/ui.list"
    for name in style.css 00-overview.html 01-signal.html 02-functions.html subpages/settings.html subpages/wifi.html subpages/shellcrash.html subpages/shellcrash-mode.sh subpages/wifi-control.sh; do
        grep -Fxq "$name" "$STAGE/ui.list" || fail "界面包缺少 ${name}；可能使用了漏掉 subpages 的旧打包命令。"
    done
    mkdir "$STAGE/ui"
    tar -xzf "$STAGE/bundle/ui.tar.gz" -C "$STAGE/ui" || fail '解压界面包失败。'
    for file in "$STAGE/ui"/subpages/*.sh; do [ ! -f "$file" ] || sh -n "$file" || fail '界面辅助脚本语法错误。'; done
    say '安装包校验通过（SHA256、架构、版本清单、页面和脚本）。'
}

snapshot() {
    backup=$(mktemp -d "$STATE/backups/$(date +%Y%m%d-%H%M%S).XXXXXX")
    chmod 700 "$backup"
    [ ! -d "$DEVUI" ] || cp -a "$DEVUI" "$backup/devui"
    [ ! -d "$DATAD" ] || cp -a "$DATAD" "$backup/datad"
    [ ! -f "$RC" ] || cp -p "$RC" "$backup/rc.local"
    [ ! -f "$BOOT" ] || cp -p "$BOOT" "$backup/boot"
    [ ! -f "$UFI_BOOT" ] || cp -p "$UFI_BOOT" "$backup/ufi-boot"
    [ ! -f "$STATE/baseline" ] || cp "$STATE/baseline" "$backup/baseline"
    [ ! -f "$STATE/autostart" ] || cp "$STATE/autostart" "$backup/autostart"
    mkdir "$backup/rc.d"
    for name in u60pro-devui zwrt-datad u60-datad zte_topsw_devui; do
        for link in "$ROOT"/etc/rc.d/S*"$name" "$ROOT"/etc/rc.d/K*"$name"; do
            [ ! -e "$link" ] && [ ! -L "$link" ] || cp -a "$link" "$backup/rc.d/"
        done
    done
    touch "$backup/snapshot.done"
    TXN=$backup
}

write_hook() {
    [ -f "$RC" ] || printf '#!/bin/sh\nexit 0\n' >"$RC"
    # Remove only known desktop launch lines, preserving unrelated boot commands.
    awk -v hook="$HOOK" -v desktop="$DESKTOP_HOOK_RE" -v backend="$BACKEND_HOOK_RE" '
        $0 ~ desktop || $0 ~ backend { next }
        /^[[:space:]]*exit[[:space:]]+0([[:space:]]|$)/ && !done { print hook; done=1 }
        { print }
        END { if (!done) print hook }
    ' "$RC" >"$STAGE/rc.local"
    cat "$STAGE/rc.local" >"$RC"
    chmod 755 "$RC"
    remove_ufi_hooks
    for name in u60pro-devui zwrt-datad u60-datad; do
        service "$ROOT/etc/init.d/$name" disable
        rm -f "$ROOT"/etc/rc.d/S*"$name" "$ROOT"/etc/rc.d/K*"$name"
    done
    service "$VENDOR" enable
}

remove_ufi_hooks() {
    for file in "$BOOT" "$UFI_BOOT"; do
        [ -f "$file" ] || continue
        awk -v desktop="$DESKTOP_HOOK_RE" -v backend="$BACKEND_HOOK_RE" '$0 !~ desktop && $0 !~ backend' "$file" >"$STAGE/ufi-boot"
        cat "$STAGE/ufi-boot" >"$file"
    done
}

restore_backend_hooks() {
    base=$1
    for item in rc.local boot ufi-boot; do
        case "$item" in rc.local) dest=$RC ;; boot) dest=$BOOT ;; ufi-boot) dest=$UFI_BOOT ;; esac
        [ -f "$base/$item" ] || continue
        awk -v backend="$BACKEND_HOOK_RE" '$0 ~ backend' "$base/$item" >"$STAGE/backend-hooks"
        [ -s "$STAGE/backend-hooks" ] || continue
        awk -v hooks="$STAGE/backend-hooks" -v backend="$BACKEND_HOOK_RE" '
            $0 ~ backend { next }
            /^[[:space:]]*exit[[:space:]]+0([[:space:]]|$)/ && !done { while ((getline line < hooks)>0) print line; close(hooks); done=1 }
            { print }
            END { if (!done) while ((getline line < hooks)>0) print line }
        ' "$dest" >"$STAGE/backend-boot"
        cat "$STAGE/backend-boot" >"$dest"
    done
    for link in "$base"/rc.d/S*zwrt-datad "$base"/rc.d/K*zwrt-datad "$base"/rc.d/S*u60-datad "$base"/rc.d/K*u60-datad; do
        [ ! -e "$link" ] && [ ! -L "$link" ] || cp -a "$link" "$ROOT/etc/rc.d/"
    done
}

# Changing boot preferences must leave the currently running desktop untouched.
backup_boot_settings() {
    boot_backup=$(mktemp -d "$STATE/backups/autostart-$(date +%Y%m%d-%H%M%S).XXXXXX")
    mkdir "$boot_backup/rc.d"
    for item in rc.local boot ufi-boot; do
        case "$item" in rc.local) file=$RC ;; boot) file=$BOOT ;; ufi-boot) file=$UFI_BOOT ;; esac
        [ ! -f "$file" ] || cp -p "$file" "$boot_backup/$item"
    done
    [ ! -f "$STATE/autostart" ] || cp "$STATE/autostart" "$boot_backup/autostart"
    for name in u60pro-devui zwrt-datad u60-datad zte_topsw_devui; do
        for link in "$ROOT"/etc/rc.d/S*"$name" "$ROOT"/etc/rc.d/K*"$name"; do
            [ ! -e "$link" ] && [ ! -L "$link" ] || cp -a "$link" "$boot_backup/rc.d/"
        done
    done
    touch "$boot_backup/boot-settings.done"
    BOOT_TXN=$boot_backup
}

restore_boot_settings() {
    boot_saved=$1
    for item in rc.local boot ufi-boot; do
        case "$item" in rc.local) file=$RC ;; boot) file=$BOOT ;; ufi-boot) file=$UFI_BOOT ;; esac
        if [ -f "$boot_saved/$item" ]; then cp -p "$boot_saved/$item" "$file"; else rm -f "$file"; fi
    done
    for name in u60pro-devui zwrt-datad u60-datad zte_topsw_devui; do
        rm -f "$ROOT"/etc/rc.d/S*"$name" "$ROOT"/etc/rc.d/K*"$name"
    done
    cp -a "$boot_saved/rc.d/." "$ROOT/etc/rc.d/"
    if [ -f "$boot_saved/autostart" ]; then cp "$boot_saved/autostart" "$STATE/autostart"; else rm -f "$STATE/autostart"; fi
}

remove_desktop_hooks() {
    for file in "$RC" "$BOOT" "$UFI_BOOT"; do
        [ -f "$file" ] || continue
        awk -v desktop="$DESKTOP_HOOK_RE" '$0 !~ desktop' "$file" >"$STAGE/desktop-boot"
        cat "$STAGE/desktop-boot" >"$file"
    done
    service "$ROOT/etc/init.d/u60pro-devui" disable
    rm -f "$ROOT"/etc/rc.d/S*u60pro-devui "$ROOT"/etc/rc.d/K*u60pro-devui
}

shared_backend_baseline() {
    baseline_name=$(cat "$STATE/baseline" 2>/dev/null || true)
    case "$baseline_name" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
    baseline_dir=$STATE/backups/$baseline_name
    [ ! -f "$baseline_dir/snapshot.done" ] || restore_backend_hooks "$baseline_dir"
}

startup_mode() {
    if [ -f "$STATE/autostart" ] && [ "$(cat "$STATE/autostart")" = off ]; then
        say off
    elif [ -f "$RC" ] && grep -Fq '# ashbell_devui' "$RC"; then
        say on
    else
        say off
    fi
}

apply_autostart() {
    requested=$1
    case "$requested" in
        on) write_hook ;;
        off) remove_desktop_hooks; shared_backend_baseline; service "$VENDOR" enable ;;
        *) fail '自启动仅支持 on、off、status。' ;;
    esac
    printf '%s\n' "$requested" >"$STATE/autostart"
}

autostart_status() {
    say "autostart=$(startup_mode)"
    hook_count=0
    for file in "$RC" "$BOOT" "$UFI_BOOT"; do
        [ -f "$file" ] || continue
        count=$(awk -v desktop="$DESKTOP_HOOK_RE" '!/^[[:space:]]*#/ && $0 ~ desktop {n++} END {print n+0}' "$file")
        [ "$count" = 0 ] || say "desktop_hook=${file#"$ROOT"}:$count"
        hook_count=$((hook_count + count))
    done
    say "desktop_hook_count=$hook_count"
    [ "$hook_count" -le 1 ] || say 'autostart_warning=duplicate_desktop_hooks'
    if [ "$(startup_mode)" = off ] && [ "$hook_count" -gt 0 ]; then say 'autostart_warning=unexpected_desktop_hook'; fi
}

autostart() {
    requested=${1:-status}
    if [ "$requested" = status ]; then autostart_status; return; fi
    case "$requested" in on|off) ;; *) fail '自启动仅支持 on、off、status。' ;; esac
    [ -f "$DEVUI/.ashbell-owned" ] || fail '尚未安装 Ashbell 桌面。'
    require_device
    backup_boot_settings
    apply_autostart "$requested"
    BOOT_TXN=
    say "已设置自启动=${requested}；当前桌面保持运行，重启设备后生效。"
    autostart_status
}

# Keep an explicit inventory rather than deleting unknown files or user functions.
legacy_files() {
    legacy_source=$1
    for file in "$legacy_source"/start-devui.sh "$legacy_source"/screen-*.sh \
                "$legacy_source"/cpuctl.sh "$legacy_source"/bin/ifconfig \
                "$legacy_source"/.screen-ui-backup-* "$legacy_source"/.screen-ui-last-backup "$legacy_source"/.screen-ui-stage.* \
                "$legacy_source"/ui.screen-new "$legacy_source"/ui.screen-old \
                "$legacy_source"/ui_extract "$legacy_source"/ui.tar.gz "$legacy_source"/u60pro_ui.tar.gz \
                "$legacy_source"/u60pro-devui.new; do
        [ ! -e "$file" ] && [ ! -L "$file" ] || printf '%s\n' "${file#"$legacy_source"/}"
    done
}

archive_legacy() {
    legacy_source=$1
    legacy_files "$legacy_source" >"$STAGE/legacy-files"
    [ -s "$STAGE/legacy-files" ] || return 0
    archive_dir=$(mktemp -d "$STATE/backups/cleanup-$(date +%Y%m%d-%H%M%S).XXXXXX")
    mkdir "$archive_dir/devui"
    : >"$archive_dir/moved-files"
    ARCHIVE_TXN=$archive_dir
    ARCHIVE_SOURCE=$legacy_source
    while IFS= read -r relative; do
        mkdir -p "$archive_dir/devui/$(dirname "$relative")"
        printf '%s\n' "$relative" >>"$archive_dir/moved-files"
        mv "$legacy_source/$relative" "$archive_dir/devui/$relative"
    done <"$STAGE/legacy-files"
    [ ! -d "$legacy_source/bin" ] || rmdir "$legacy_source/bin" 2>/dev/null || true
    touch "$archive_dir/cleanup.done"
    ARCHIVE_TXN=
    say "旧桌面资源已归档：$(basename "$archive_dir")"
}

cleanup_legacy() {
    [ -f "$DEVUI/.ashbell-owned" ] || fail '当前桌面不属于 Ashbell，未清理文件。'
    require_device
    stop_legacy_workers
    archive_legacy "$DEVUI"
    stale_archive=
    for dir in "$STATE"/staging.*; do
        [ -d "$dir" ] && [ "$dir" != "$STAGE" ] || continue
        if [ -z "$stale_archive" ]; then stale_archive=$(mktemp -d "$STATE/backups/cleanup-staging-$(date +%Y%m%d-%H%M%S).XXXXXX"); fi
        mv "$dir" "$stale_archive/"
    done
    [ -z "$stale_archive" ] || { touch "$stale_archive/cleanup.done"; say "未完成管理器暂存已归档：$(basename "$stale_archive")"; }
    say '残留检查与归档完成；个人配置、自定义功能和后端流量数据已保留。'
    residual_status
}

residual_status() {
    legacy_count=0; recovery_count=0
    for item in $(legacy_files "$DEVUI"); do
        case "$item" in
            .screen-ui-backup-*|.screen-ui-last-backup) say "legacy_recovery_archive=$item"; recovery_count=$((recovery_count + 1)) ;;
            *) say "legacy_resource=$item"; legacy_count=$((legacy_count + 1)) ;;
        esac
    done
    say "legacy_resource_count=$legacy_count"
    say "legacy_recovery_archives=$recovery_count (正常回退资料，可归档，不是安装失败)"
    stage_count=0
    for dir in "$STATE"/staging.*; do
        [ ! -d "$dir" ] || [ "$dir" = "$STAGE" ] || stage_count=$((stage_count + 1))
    done
    lock_pid=$(cat "$STATE/lock/pid" 2>/dev/null || true)
    case "$lock_pid" in ''|*[!0-9]*) lock_live=0 ;; *) kill -0 "$lock_pid" 2>/dev/null && lock_live=1 || lock_live=0 ;; esac
    say "staging_directories=$stage_count"
    if [ "$stage_count" -gt 0 ]; then
        [ "$lock_live" = 1 ] && say 'staging_state=active_manager' || say 'staging_state=unfinished'
    else say 'staging_state=clear'; fi
    archive_count=0
    for dir in "$STATE"/backups/*; do [ ! -d "$dir" ] || archive_count=$((archive_count + 1)); done
    say "backup_archives=$archive_count (正常备份，不计入残留故障)"
    [ ! -f "$DEVUI/.ashbell-owned" ] || say 'managed_launcher=start.sh (Ashbell正常启动器，旧管理器可能误报)'
    if [ -z "$ROOT" ]; then
        worker_count=0
        for old_pid in $(legacy_worker_pids); do
            worker_count=$((worker_count + 1))
            say "legacy_worker_pid=$old_pid"
        done
        say "legacy_worker_count=$worker_count"
    else say 'legacy_worker_state=not_measured_test_root'; fi
}

restart_desktop() {
    [ -f "$DEVUI/.ashbell-owned" ] || fail '尚未安装 Ashbell 桌面。'
    require_device
    if [ -z "$ROOT" ]; then
        killall u60pro-devui >/dev/null 2>&1 || true
        count=0
        while pidof u60pro-devui >/dev/null 2>&1 && [ "$count" -lt 5 ]; do sleep 1; count=$((count + 1)); done
        killall -9 u60pro-devui >/dev/null 2>&1 || true
    fi
    start_saved
    healthy || { service "$VENDOR" start; fail '桌面重启检查失败；已尝试恢复原厂显示，请查看诊断。'; }
    say '桌面已重启并通过状态检查；后端数据和自启动选择保持不变。'
}

diagnostics() {
    status
    say '--- diagnostics ---'
    # These logs are produced and rotated by the current renderer, not leftovers.
    for file in "$DEVUI/plugin-detect.log" "$DEVUI/plugin-detect.log.old"; do
        if [ -f "$file" ]; then
            size=$(wc -c <"$file" | tr -d ' ')
            say "runtime_log=${file#"$ROOT"} bytes=$size"
        else
            say "runtime_log_absent=${file#"$ROOT"}"
        fi
    done
    for file in "$DEVUI/u60pro-devui" "$DEVUI/start.sh" "$DATAD/zwrt-datad"; do
        [ ! -x "$file" ] && say "executable_missing=${file#"$ROOT"}" || say "executable_ready=${file#"$ROOT"}"
    done
    if [ -z "$ROOT" ]; then
        if command -v curl >/dev/null 2>&1; then
            code=$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:9460/state || true)
            say "datad_http=$code"
        fi
        for file in /tmp/u60pro-boot.log /tmp/u60pro-devui.log /tmp/zwrt-datad.log; do
            [ -f "$file" ] || continue
            size=$(wc -c <"$file" | tr -d ' ')
            errors=$(grep -Eic 'error|failed|cannot|invalid|no pages' "$file" || true)
            say "log_summary=$file bytes=$size error_lines=$errors"
        done
    fi
}

healthy() {
    [ -z "$ROOT" ] || { [ "${ASHBELL_TEST_HEALTH:-ok}" = ok ]; return; }
    count=0; stable=0
    while [ "$count" -lt 15 ]; do
        if pidof u60pro-devui >/dev/null 2>&1 && pidof zwrt-datad >/dev/null 2>&1; then
            if command -v curl >/dev/null 2>&1; then
                curl -fsS --max-time 3 http://127.0.0.1:9460/state -o /dev/null 2>/dev/null && stable=$((stable + 1)) || stable=0
            else
                wget -T 3 -qO /dev/null http://127.0.0.1:9460/state 2>/dev/null && stable=$((stable + 1)) || stable=0
            fi
        else
            stable=0
        fi
        [ "$stable" -lt 3 ] || return 0
        count=$((count + 1)); sleep 1
    done
    return 1
}

install_bundle() {
    action=$1 package=${2:-}
    desired_autostart=on
    if [ "$action" = update ]; then
        [ -f "$DEVUI/.ashbell-owned" ] || fail '尚未安装 Ashbell 桌面；请选择安装/接管。'
        desired_autostart=$(startup_mode)
    fi
    require_device
    if [ -z "$package" ]; then
        download "${SOURCE%/}/ashbell-devui.tar.gz" "$STAGE/package.tar.gz"
        package=$STAGE/package.tar.gz
    fi
    [ -f "$package" ] || fail '找不到离线安装包。'
    validate_bundle "$package"
    # Check space before backing up or stopping anything; /tmp may be a small tmpfs.
    need=$(du -sk "$DEVUI" "$DATAD" "$STAGE" 2>/dev/null | awk '{s+=$1} END {print s*2+8192}')
    free=$(df -Pk "$STATE" | awk 'END {print $4}')
    [ "$free" -ge "$need" ] || fail "空间不足：至少需要 ${need} KiB，剩余 ${free} KiB。"
    snapshot
    say "完整备份已保存：$backup"
    stop_desktop
    # datad flushes its current traffic counters on SIGTERM. Capture the flushed
    # state in both the recovery snapshot and the replacement directory.
    [ ! -d "$DATAD" ] || cp -a "$DATAD/." "$backup/datad/"
    mkdir "$STAGE/new-devui" "$STAGE/new-datad"
    # Keep per-device settings, lock PIN, custom functions and datad auth token.
    [ ! -d "$DEVUI" ] || cp -a "$DEVUI/." "$STAGE/new-devui/"
    [ ! -d "$DATAD" ] || cp -a "$DATAD/." "$STAGE/new-datad/"
    if [ -d "$STAGE/new-devui/ui/functions" ]; then cp -a "$STAGE/new-devui/ui/functions" "$STAGE/custom-functions"; fi
    if [ -f "$STAGE/new-devui/ui/.lockpin" ]; then cp -p "$STAGE/new-devui/ui/.lockpin" "$STAGE/lockpin"; fi
    rm -rf "$STAGE/new-devui/ui"
    mkdir "$STAGE/new-devui/ui"
    [ ! -d "$STAGE/custom-functions" ] || cp -a "$STAGE/custom-functions" "$STAGE/new-devui/ui/functions"
    # New managed pages win over old versions; unknown user functions survive.
    cp -a "$STAGE/ui/." "$STAGE/new-devui/ui/"
    [ ! -f "$STAGE/lockpin" ] || cp -p "$STAGE/lockpin" "$STAGE/new-devui/ui/.lockpin"
    cp "$STAGE/bundle/u60pro-devui-aarch64" "$STAGE/new-devui/u60pro-devui"
    cp "$STAGE/bundle/zwrt-datad-aarch64" "$STAGE/new-datad/zwrt-datad"
    cp "$STAGE/bundle/start.sh" "$STAGE/new-devui/start.sh"
    cp "$STAGE/bundle/ashbell-devui.sh" "$STAGE/new-devui/ashbell-devui.sh"
    cp "$STAGE/bundle/version.json" "$STAGE/new-devui/version.json"
    cp "$STAGE/bundle/LICENSE" "$STAGE/new-devui/LICENSE"
    cp "$STAGE/bundle/NOTICE.md" "$STAGE/new-devui/NOTICE.md"
    printf 'Ashbell DevUI\n' >"$STAGE/new-devui/.ashbell-owned"
    archive_legacy "$STAGE/new-devui"
    chmod 755 "$STAGE/new-devui"/u60pro-devui "$STAGE/new-devui"/start.sh "$STAGE/new-devui"/ashbell-devui.sh "$STAGE/new-datad/zwrt-datad"
    [ ! -d "$DEVUI" ] || mv "$DEVUI" "$STAGE/previous-devui"
    [ ! -d "$DATAD" ] || mv "$DATAD" "$STAGE/previous-datad"
    mv "$STAGE/new-devui" "$DEVUI"
    mv "$STAGE/new-datad" "$DATAD"
    apply_autostart "$desired_autostart"
    start_saved
    healthy || fail '桌面或 datad 健康检查失败，正在自动恢复。请通过 ADB 查看 /tmp/u60pro-boot.log 与 /tmp/zwrt-datad.log。'
    # Remember the original shared datad only once, for uninstall restoration.
    [ -f "$STATE/baseline" ] || printf '%s\n' "$(basename "$backup")" >"$STATE/baseline"
    printf '%s\n' "$(basename "$backup")" >"$STATE/last-backup"
    TXN=
    say "Ashbell 桌面 $action 成功；已验证进程与本机状态接口。备份：$(basename "$backup")"
}

status() {
    if [ -f "$DEVUI/.ashbell-owned" ]; then say 'desktop=ashbell'; else say 'desktop=other_or_absent'; fi
    if [ -f "$DEVUI/version.json" ]; then cat "$DEVUI/version.json"; fi
    if [ -z "$ROOT" ]; then
        pidof u60pro-devui >/dev/null 2>&1 && say 'devui=running' || say 'devui=stopped'
        pidof zwrt-datad >/dev/null 2>&1 && say 'datad=running' || say 'datad=stopped'
    else say 'runtime=not_measured_test_root'; fi
    [ ! -f "$STATE/last-backup" ] || { printf 'last_backup='; cat "$STATE/last-backup"; }
    autostart_status
    residual_status
}

uninstall() {
    [ -f "$DEVUI/.ashbell-owned" ] || fail '当前目录不属于 Ashbell 桌面，未执行删除。'
    require_device
    snapshot
    stop_desktop
    awk -v desktop="$DESKTOP_HOOK_RE" -v backend="$BACKEND_HOOK_RE" '$0 !~ desktop && $0 !~ backend' "$RC" >"$STAGE/rc.local"
    cat "$STAGE/rc.local" >"$RC"
    remove_ufi_hooks
    for name in u60pro-devui zwrt-datad u60-datad; do
        service "$ROOT/etc/init.d/$name" disable
        rm -f "$ROOT"/etc/rc.d/S*"$name" "$ROOT"/etc/rc.d/K*"$name"
    done
    rm -rf "$DEVUI"
    # datad may predate this desktop or serve another plugin: restore its baseline.
    baseline=$(cat "$STATE/baseline" 2>/dev/null || true)
    case "$baseline" in ''|*[!A-Za-z0-9._-]*) fail '缺少有效基线备份，自动恢复。' ;; esac
    [ -f "$STATE/backups/$baseline/snapshot.done" ] || fail '基线备份不完整，自动恢复。'
    if [ -d "$STATE/backups/$baseline/datad" ]; then
        restore_backend_hooks "$STATE/backups/$baseline"
        if [ -z "$ROOT" ]; then
            if [ -f "$DATAD/start-datad.sh" ]; then sh "$DATAD/start-datad.sh" >/dev/null 2>&1; else service "$ROOT/etc/init.d/zwrt-datad" start; fi
        fi
    else
        rm -rf "$DATAD"
    fi
    service "$VENDOR" enable
    service "$VENDOR" start
    if [ -z "$ROOT" ]; then sleep 2; pidof zte_topsw_devui >/dev/null 2>&1 || fail '原厂桌面未启动，自动恢复卸载前状态。'; fi
    printf '%s\n' "$(basename "$backup")" >"$STATE/last-backup"
    rm -f "$STATE/baseline" "$STATE/autostart"
    TXN=
    say "Ashbell 桌面已卸载，原厂桌面已启动；备份与个人设置保留于 $STATE/backups。"
}

rollback() {
    require_device
    wanted=${1:-$(cat "$STATE/last-backup" 2>/dev/null || true)}
    case "$wanted" in ''|*[!A-Za-z0-9._-]*) fail '请指定有效备份名。' ;; esac
    target=$STATE/backups/$wanted
    [ -f "$target/snapshot.done" ] || fail '备份不存在或不完整。'
    snapshot
    restore "$target" || fail '回滚失败，正在恢复回滚前状态。'
    if [ -f "$DEVUI/.ashbell-owned" ]; then healthy || fail '回滚后的桌面健康检查失败。'; fi
    printf '%s\n' "$(basename "$backup")" >"$STATE/last-backup"
    TXN=
    say "已回滚至备份 ${wanted}；回滚前状态保存在 $(basename "$backup")。"
}

case "${1:-help}" in
    install|update) command=$1; shift; install_bundle "$command" "${1:-}" ;;
    uninstall) uninstall ;;
    rollback) rollback "${2:-}" ;;
    status) status ;;
    autostart) autostart "${2:-status}" ;;
    cleanup) cleanup_legacy ;;
    restart) restart_desktop ;;
    diagnostics) diagnostics ;;
    backups) [ ! -d "$STATE/backups" ] || ls -1 "$STATE/backups" ;;
    validate) require_device; [ -f "${2:-}" ] || fail '用法：validate /path/ashbell-devui.tar.gz'; validate_bundle "$2" ;;
    *) say "用法：sh $0 {install|update} [离线安装包路径]"
       say "      sh $0 {status|diagnostics|cleanup|restart|backups|rollback [备份名]|uninstall}"
       say "      sh $0 autostart {on|off|status}"
       say '在线源：ASHBELL_RELEASE_URL=https://.../releases/latest/download'
       say '卸载保留备份；回滚恢复该次操作前的桌面和启动设置。' ;;
esac
