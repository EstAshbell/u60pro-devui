#!/usr/bin/env python3
"""Run CPU/ShellCrash completion paths with isolated fake device adapters."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

CPU = r'''#!/bin/sh
if [ "$1" != status ]; then
    [ "${CPU_SLEEP:-0}" != 1 ] || sleep 30
    if [ "${CPU_FAIL:-0}" = 1 ]; then
        echo '模拟 CPU 写入失败' >&2
        rc=1
    else
        [ "${CPU_NO_APPLY:-0}" = 1 ] || echo "$1" >"$CPU_STATE"
        rc=0
    fi
else rc=0; fi
printf 'CPU_INST=1\nCPU_MODE=%s\nCPU_GOV=schedutil\nCPU_CUR=800\nCPU_MIN=300\nCPU_MAX=1200\n' "$(cat "$CPU_STATE")"
exit "$rc"
'''

SHELLCRASH = r'''#!/bin/sh
[ "${SC_FAIL:-0}" != 1 ] || { echo '模拟服务启动失败' >&2; exit 7; }
[ "${SC_NO_INSTANCE:-0}" != 1 ] || exit 0
case "$1" in start) touch "$SC_MARKER" ;; stop) rm -f "$SC_MARKER" ;; *) exit 2 ;; esac
'''

PROBE = r'''
#define main devui_application_main
#include "@SOURCE@"
#undef main
#include <assert.h>
static const char *test_network_mode = "Only_LTE";
static int test_network_available = 1;
int data_refresh_live(devui_data_t *state) {
    memset(state, 0, sizeof *state);
    snprintf(state->net_select, sizeof state->net_select, "%s", test_network_mode);
    return test_network_available;
}
static void await_network_receipt(void) {
    for (int i = 0; i < 200 && access(g_net_result_path, R_OK) != 0; ++i) usleep(5000);
    assert(access(g_net_result_path, R_OK) == 0);
}
static void finish_cpu(void) {
    for (int i = 0; i < 300 && g_cpu_pid > 0; ++i) {
        cpu_action_poll(millis()); usleep(5000);
    }
    assert(g_cpu_pid == 0);
}
static void finish_sc(void) {
    for (int i = 0; i < 600 && g_sc_pending_action; ++i) {
        shellcrash_action_poll(millis()); usleep(5000);
    }
    assert(g_sc_pending_action == 0);
}
int main(void) {
    refresh_cpu_status();
    assert(g_cpu_installed && !strcmp(g_cpu_mode, "balance"));
    assert(cpu_start_action("powersave", millis()) == 1);
    assert(cpu_start_action("balance", millis()) == 0);
    finish_cpu();
    assert(strstr(g_toast, "成功") && !strcmp(g_cpu_mode, "powersave"));
    setenv("CPU_FAIL", "1", 1);
    assert(cpu_start_action("performance", millis()) == 1);
    finish_cpu();
    assert(strstr(g_toast, "失败") && !strcmp(g_cpu_mode, "powersave"));
    char *log = read_file(CPU_ACTION_LOG);
    assert(log && strstr(log, "模拟 CPU 写入失败")); free(log);
    unsetenv("CPU_FAIL"); setenv("CPU_NO_APPLY", "1", 1);
    assert(cpu_start_action("balance", millis()) == 1);
    finish_cpu();
    assert(strstr(g_toast, "失败"));
    unsetenv("CPU_NO_APPLY"); setenv("CPU_SLEEP", "1", 1);
    assert(cpu_start_action("balance", millis()) == 1);
    g_cpu_pending_since = millis() - 15001;
    assert(cpu_action_poll(millis()) && strstr(g_toast, "超时"));
    unsetenv("CPU_SLEEP");

    shellcrash_poll(millis(), 1);
    assert(g_sc.installed && !g_sc.running);
    assert(shellcrash_run_action(1, millis()) == 1);
    assert(shellcrash_run_action(2, millis()) == 0);
    g_sc_pending_since -= 1001;
    finish_sc();
    assert(g_sc.running && strstr(g_toast, "启动"));
    assert(shellcrash_set_mode("global") == -1);  /* PATCH says OK, GET disagrees */
    assert(!strcmp(g_sc.mode, "rule"));
    assert(shellcrash_set_mode("rule") == 1);
    assert(shellcrash_set_mode("arbitrary") == 0);
    assert(shellcrash_run_action(2, millis()) == 1);
    g_sc_pending_since -= 1001;
    finish_sc();
    assert(!g_sc.running && strstr(g_toast, "停止"));
    setenv("SC_FAIL", "1", 1);
    assert(shellcrash_run_action(1, millis()) == 1);
    finish_sc();
    assert(!g_sc.running && strstr(g_toast, "失败"));
    unsetenv("SC_FAIL"); setenv("SC_NO_INSTANCE", "1", 1);
    assert(shellcrash_run_action(1, millis()) == 1);
    for (int i = 0; i < 300 && g_sc_pid > 0; ++i) {
        shellcrash_action_poll(millis()); usleep(5000);
    }
    assert(g_sc_pid == 0 && g_sc_pending_action == 1);
    g_sc_pending_until = millis() - 1;
    assert(shellcrash_action_poll(millis()) && strstr(g_toast, "超时"));
    assert(!g_sc_pending_action);
    unlink(SHELLCRASH_START);
    shellcrash_poll(millis(), 1);
    assert(!g_sc.installed && !g_sc.running);
    assert(shellcrash_run_action(1, millis()) == -1);

    char modes[640];
    network_mode_html(modes, sizeof modes, "unknown-mode");
    assert(strstr(modes, "状态未知") && !strstr(modes, "seg-on"));
    assert(network_mode_request("Only_5G", millis()) == 1);
    assert(network_mode_request("Only_LTE", millis()) == 0);
    assert(network_mode_request("arbitrary", millis()) == -1);
    await_network_receipt();
    network_mode_html(modes, sizeof modes, "Only_LTE");
    assert(strstr(modes, "act:net:Only_LTE' class='segc seg-on'"));
    assert(!strstr(modes, "act:net:Only_5G' class='segc seg-on'"));
    assert(strstr(modes, "正在切换至"));
    assert(network_mode_poll(millis()) == 0 && g_net_pending[0]);
    test_network_mode = "Only_5G";
    g_net_poll_at = millis() - 250;
    assert(network_mode_poll(millis()) && !g_net_pending[0] && strstr(g_toast, "已切换"));
    setenv("NET_FAIL", "1", 1);
    assert(network_mode_request("Only_LTE", millis()) == 1);
    await_network_receipt();
    assert(network_mode_poll(millis()) && strstr(g_toast, "命令失败"));
    unsetenv("NET_FAIL");
    assert(network_mode_request("Only_LTE", millis()) == 1);
    await_network_receipt();
    test_network_available = 0;  /* transport suspended/dark: timer still finishes */
    g_net_pending_since = millis() - 15001;
    assert(network_mode_poll(millis()) && !g_net_pending[0] && strstr(g_toast, "未确认"));
    puts("runtime control tests passed");
    return 0;
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix="u60-runtime-test-") as directory:
        base = Path(directory)
        ui = base / "ui"
        (ui / "functions").mkdir(parents=True)
        (ui / "subpages").mkdir()
        (base / "bin").mkdir()
        policy = base / "policy"
        policy.mkdir()
        (policy / "scaling_governor").write_text("schedutil\n")
        (ui / "functions/cpuctl.sh").write_text(CPU)
        (ui / "subpages/shellcrash-mode.sh").write_text("#!/bin/sh\n[ \"$1\" != get ] || echo MODE=rule\nexit 0\n")
        start = base / "start.sh"
        start.write_text(SHELLCRASH)
        (base / "bin/pidof").write_text("#!/bin/sh\n[ \"$1\" = CrashCore ] && [ -f \"$SC_MARKER\" ] && echo 123\n")
        (base / "bin/pidof").chmod(0o755)
        ubus = base / "bin/ubus"
        ubus.write_text("#!/bin/sh\n[ \"${NET_FAIL:-0}\" != 1 ] || exit 7\nexit 0\n")
        ubus.chmod(0o755)
        state = base / "cpu-mode"
        state.write_text("balance\n")
        env = dict(os.environ, CPU_STATE=str(state), SC_MARKER=str(base / "running"),
                   PATH=str(base / "bin") + os.pathsep + os.environ["PATH"])
        probe = base / "probe.c"
        probe.write_text(PROBE.replace("@SOURCE@", str(ROOT / "src/htmlmain.c")))
        binary = base / "probe"
        flags = ["-std=c11", "-D_GNU_SOURCE", "-ffunction-sections", "-fdata-sections",
                 "-I", str(ROOT / "include"), "-I", str(ROOT / "third_party/stb"),
                 f'-DUI_DIR="{ui}"', f'-DDEVUI_CPU_POLICY_DIR="{policy}"',
                 f'-DSHELLCRASH_START="{start}"', f'-DCPU_ACTION_LOG="{base / "cpu.log"}"',
                 f'-DSHELLCRASH_LOG="{base / "sc.log"}"',
                 f'-DSHELLCRASH_MODE_LOG="{base / "sc-mode.log"}"',
                 f'-DDEVUI_UBUS_BIN="{ubus}"',
                 f'-DDEVUI_NETMODE_LOG="{base / "net.log"}"',
                 f'-DDEVUI_NETMODE_RESULT_PREFIX="{base / "net-result"}"']
        if sys.platform == "darwin":
            flags += ["-Dst_mtim=st_mtimespec", "-Wl,-dead_strip"]
        else:
            flags += ["-Wl,--gc-sections"]
        command = shlex.split(os.environ.get("CC", "cc")) + flags + [
            str(probe), "-pthread", "-lm", "-o", str(binary)]
        subprocess.run(command, check=True)
        subprocess.run([str(binary)], env=env, check=True, timeout=10)


if __name__ == "__main__":
    main()
