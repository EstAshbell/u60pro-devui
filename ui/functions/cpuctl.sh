#!/bin/sh
# Ashbell CPU controller for the DevUI CPU_* status protocol.
# Runtime settings only; the device's normal boot policy remains authoritative.
# SPDX-License-Identifier: MIT
set -u

SYS=${U60_CPU_SYS:-/sys/devices/system/cpu/cpufreq}

read_value() { tr -d ' \t\r\n' < "$1" 2>/dev/null; }
frequency_ok() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -gt 0 ] 2>/dev/null
}
policies() {
    for policy in "$SYS"/policy[0-9]*; do
        [ ! -d "$policy" ] || printf '%s\n' "$policy"
    done
}
status() {
    first=$(policies | head -n 1)
    if [ -z "$first" ] || [ ! -r "$first/scaling_governor" ]; then
        echo 'CPU_INST=0'
        return
    fi
    governor=$(read_value "$first/scaling_governor")
    minimum=$(read_value "$first/scaling_min_freq")
    maximum=$(read_value "$first/scaling_max_freq")
    hardware_max=$(read_value "$first/cpuinfo_max_freq")
    current=$(read_value "$first/scaling_cur_freq")
    mode=custom
    case "$governor" in
        schedutil|ondemand|interactive|conservative) mode=balance ;;
        powersave) mode=powersave ;;
        performance)
            mode=performance
            if [ "$minimum" = "$hardware_max" ] && [ "$maximum" = "$hardware_max" ]; then
                mode=extreme
            fi ;;
    esac
    echo 'CPU_INST=1'
    printf 'CPU_MODE=%s\nCPU_GOV=%s\n' "$mode" "$governor"
    for item in "CUR:$current" "MIN:$minimum" "MAX:$maximum"; do
        field=${item%%:*}; value=${item#*:}
        if frequency_ok "$value"; then value=$((value / 1000)); else value=0; fi
        printf 'CPU_%s=%s\n' "$field" "$value"
    done
}
choose_governor() {
    available=$(cat "$1/scaling_available_governors" 2>/dev/null || true)
    case "$2" in
        balance) candidates='schedutil ondemand interactive conservative' ;;
        powersave) candidates=powersave ;;
        performance|extreme) candidates=performance ;;
    esac
    for candidate in $candidates; do
        case " $available " in *" $candidate "*) printf '%s\n' "$candidate"; return 0 ;; esac
    done
    return 1
}
restore() {
    for snapshot in "$transaction"/policy[0-9]*; do
        [ -d "$snapshot" ] || continue
        policy="$SYS/${snapshot##*/}"
        # First release a previous high minimum before restoring a lower maximum.
        cat "$policy/cpuinfo_max_freq" > "$policy/scaling_max_freq" 2>/dev/null || true
        cat "$snapshot/min" > "$policy/scaling_min_freq" 2>/dev/null || true
        cat "$snapshot/max" > "$policy/scaling_max_freq" 2>/dev/null || true
        cat "$snapshot/governor" > "$policy/scaling_governor" 2>/dev/null || true
    done
}
apply() {
    wanted=$1
    [ -n "$(policies)" ] || { echo 'CPU 控制接口不存在' >&2; return 1; }
    transaction=$(mktemp -d /tmp/ashbell-cpu.XXXXXX) || return 1
    trap 'rm -rf "$transaction"' EXIT
    trap 'restore; exit 1' HUP INT TERM

    # Validate every policy and retain the old values before writing any policy.
    for policy in $(policies); do
        minimum=$(read_value "$policy/cpuinfo_min_freq")
        maximum=$(read_value "$policy/cpuinfo_max_freq")
        if ! frequency_ok "$minimum" || ! frequency_ok "$maximum" || [ "$minimum" -gt "$maximum" ]; then
            echo "CPU 频率范围无效: ${policy##*/}" >&2; return 1
        fi
        governor=$(choose_governor "$policy" "$wanted") || {
            echo "CPU 不支持此模式: ${policy##*/} / $wanted" >&2; return 1;
        }
        snapshot="$transaction/${policy##*/}"
        mkdir "$snapshot" || return 1
        cp "$policy/scaling_governor" "$snapshot/governor" &&
        cp "$policy/scaling_min_freq" "$snapshot/min" &&
        cp "$policy/scaling_max_freq" "$snapshot/max" || return 1
        [ "$wanted" != extreme ] || minimum=$maximum
        printf '%s\n' "$governor" > "$snapshot/new-governor"
        printf '%s\n' "$minimum" > "$snapshot/new-min"
        printf '%s\n' "$maximum" > "$snapshot/new-max"
    done
    for snapshot in "$transaction"/policy[0-9]*; do
        policy="$SYS/${snapshot##*/}"
        if ! { cat "$snapshot/new-max" > "$policy/scaling_max_freq" &&
               cat "$snapshot/new-min" > "$policy/scaling_min_freq" &&
               cat "$snapshot/new-governor" > "$policy/scaling_governor"; }; then
            echo "CPU 设置失败，恢复之前的模式: ${policy##*/}" >&2
            restore
            return 1
        fi
        if [ "$(read_value "$policy/scaling_min_freq")" != "$(read_value "$snapshot/new-min")" ] ||
           [ "$(read_value "$policy/scaling_max_freq")" != "$(read_value "$snapshot/new-max")" ] ||
           [ "$(read_value "$policy/scaling_governor")" != "$(read_value "$snapshot/new-governor")" ]; then
            echo "CPU 状态回读不一致，恢复之前的模式: ${policy##*/}" >&2
            restore
            return 1
        fi
    done
    return 0
}

result=0
case "${1:-status}" in
    status) ;;
    powersave|balance|performance|extreme) apply "$1" || result=$? ;;
    *) echo '用法: cpuctl.sh status|powersave|balance|performance|extreme' >&2; exit 2 ;;
esac
status
exit "$result"
