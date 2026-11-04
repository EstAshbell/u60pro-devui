#!/usr/bin/env python3
"""Read fake per-band UCI profiles through the real async/HTML display path."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]

PROBE = r'''
#define main devui_application_main
#include "@SOURCE@"
#undef main
#include <assert.h>
static int count_spans(const char *text) {
    int count = 0;
    while ((text = strstr(text, "<span class='wifi-char'>"))) { count++; text++; }
    return count;
}
static void await_profiles(void) {
    for (int i = 0; i < 500 && g_wifi_info_pid > 0; ++i) {
        wifi_profiles_poll(millis()); usleep(5000);
    }
    assert(g_wifi_info_pid == 0 && g_wifi_info_fd == -1);
}
int main(void) {
    wifi_profiles_refresh_async(millis());
    assert(g_wifi_info_pid > 0);
    pid_t worker = g_wifi_info_pid;
    wifi_profiles_refresh_async(millis());
    assert(g_wifi_info_pid == worker);  /* a refresh never overlaps itself */
    await_profiles();
    assert(g_wifi_profile5.ssid_ok && g_wifi_profile5.key_ok && g_wifi_profile5.enc_ok);
    assert(!strcmp(g_wifi_profile5.ssid, "Five<&>\"'\nWIFI_CRED 24K 0 4\n"));
    assert(!strcmp(g_wifi_profile24.ssid, "Two-only"));
    assert(strlen(g_wifi_profile5.key) == 63);
    assert(!strcmp(g_wifi_profile24.key, "two-password"));

    devui_data_t backend = {0};
    snprintf(backend.wifi_ssid, sizeof backend.wifi_ssid, "legacy-two");
    snprintf(backend.wifi_key, sizeof backend.wifi_key, "legacy-two-password");
    snprintf(backend.wifi_enc, sizeof backend.wifi_enc, "psk2");
    struct wifi_profile band24, band5;
    const char *band;
    const struct wifi_profile *selected = wifi_display_profiles(&backend, &band24, &band5, &band);
    assert(selected == &band5 && !strcmp(band, "5G"));
    char password[DEVUI_WIFI_KEY_MAX + 1];
    wifi_profile_key_text(selected, password, sizeof password);
    assert(!strcmp(password, "****************"));
    g_show_key = 1;
    wifi_profile_key_text(selected, password, sizeof password);
    assert(strlen(password) == 63 && !strcmp(password, g_wifi_profile5.key));
    char ssid_html[DEVUI_WIFI_SSID_MAX * 48 + 1];
    char key_html[DEVUI_WIFI_KEY_MAX * 48 + 1], enc_html[3073];
    wifi_profile_html(selected, ssid_html, sizeof ssid_html, key_html, sizeof key_html, enc_html, sizeof enc_html);
    assert(count_spans(key_html) == 63);
    assert(strstr(key_html, "&amp;</span>") && strstr(key_html, "&lt;</span>"));
    assert(strstr(key_html, "&gt;</span>") && strstr(key_html, "&quot;</span>"));
    assert(!strcmp(key_html + strlen(key_html) - strlen("&#39;</span>"), "&#39;</span>"));
    assert(!strstr(ssid_html, "<script>") && strstr(ssid_html, "&lt;</span>"));

    /* 64 hex characters (raw PSK) and 63 worst-case entities are both complete. */
    memset(band5.key, 'a', 64); band5.key[64] = 0; band5.key_ok = 1;
    wifi_profile_key_text(&band5, password, sizeof password);
    assert(strlen(password) == 64);
    assert(wifi_chars_html(key_html, sizeof key_html, password) && count_spans(key_html) == 64);
    memset(password, '\"', 63); password[63] = 0;
    assert(wifi_chars_html(key_html, sizeof key_html, password) && count_spans(key_html) == 63);
    assert(!strcmp(key_html + strlen(key_html) - strlen("&quot;</span>"), "&quot;</span>"));
    char escaped[DEVUI_WIFI_KEY_MAX * 6 + 1];
    assert(wifi_text_escape(escaped, sizeof escaped, password) && strlen(escaped) == 63 * 6);
    assert(wifi_chars_html(ssid_html, sizeof ssid_html, "甲&乙") && count_spans(ssid_html) == 3);
    assert(wifi_chars_html(ssid_html, sizeof ssid_html, " a  ") && count_spans(ssid_html) == 4);
    assert(strstr(ssid_html, "&#32;</span>") && !strstr(ssid_html, "&nbsp;"));

    /* Missing 5G credentials never borrow a 2.4G password or encryption. */
    g_wifi_profile5.key_ok = 0; g_wifi_profile5.key[0] = 0;
    selected = wifi_display_profiles(&backend, &band24, &band5, &band);
    assert(selected == &band24 && !strcmp(band, "2.4G"));
    wifi_profile_key_text(&band5, password, sizeof password);
    assert(!strcmp(password, "未读取到密码"));
    band5.enc_ok = 0;
    wifi_profile_html(&band5, ssid_html, sizeof ssid_html, key_html, sizeof key_html, enc_html, sizeof enc_html);
    assert(!strstr(enc_html, "psk2"));
    band5.enc_ok = 1; strcpy(band5.enc, "none");
    wifi_profile_key_text(&band5, password, sizeof password);
    assert(!strcmp(password, "无密码"));
    band5.enc_ok = 0;
    wifi_profile_key_text(&band5, password, sizeof password);
    assert(!strcmp(password, "未读取到密码"));

    /* A stuck collector is killed as one group; old values become unknown. */
    FILE *script = fopen(WIFI_INFO, "w");
    assert(script); fputs("#!/bin/sh\nsleep 30\n", script); fclose(script);
    wifi_profiles_refresh_async(millis());
    assert(g_wifi_info_pid > 0);
    g_wifi_info_since = millis() - 2001;
    assert(wifi_profiles_poll(millis()));
    assert(g_wifi_info_pid == 0 && g_wifi_info_fd == -1);
    assert(!g_wifi_profile5.ssid_ok && !g_wifi_profile24.ssid_ok);
    puts("wifi profile tests passed");
    return 0;
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix="u60-wifi-profiles-") as directory:
        base = Path(directory)
        ui = base / "ui"
        (ui / "subpages").mkdir(parents=True)
        shutil.copyfile(ROOT / "ui/subpages/wifi-info.sh", ui / "subpages/wifi-info.sh")
        data = base / "profiles.json"
        data.write_text(json.dumps({
            "wireless.main_2g.ssid": "Two-only",
            "wireless.main_2g.key": "two-password",
            "wireless.main_2g.encryption": "psk2",
            "wireless.main_5g.ssid": "Five<&>\"'\nWIFI_CRED 24K 0 4\n",
            "wireless.main_5g.key": "W" * 58 + "&<>\"'",
            "wireless.main_5g.encryption": "psk2+ccmp",
        }))
        uci = base / "uci"
        uci.write_text(f"#!{sys.executable}\n" +
                       "import json,os,sys\n" +
                       "d=json.load(open(os.environ['WIFI_TEST_PROFILES']))\n" +
                       "key=sys.argv[-1]\n" +
                       "if key not in d: sys.exit(1)\n" +
                       "sys.stdout.write(d[key]+'\\n')\n")
        uci.chmod(0o755)
        env = dict(os.environ, DEVUI_WIFI_UCI_BIN=str(uci), WIFI_TEST_PROFILES=str(data))
        probe = base / "probe.c"
        probe.write_text(PROBE.replace("@SOURCE@", str(ROOT / "src/htmlmain.c")))
        binary = base / "probe"
        flags = ["-std=c11", "-D_GNU_SOURCE", "-ffunction-sections", "-fdata-sections",
                 "-I", str(ROOT / "include"), "-I", str(ROOT / "third_party/stb"), f'-DUI_DIR="{ui}"']
        if sys.platform == "darwin":
            flags += ["-Dst_mtim=st_mtimespec", "-Wl,-dead_strip"]
        else:
            flags += ["-Wl,--gc-sections"]
        command = shlex.split(os.environ.get("CC", "cc")) + flags + [str(probe), "-pthread", "-lm", "-o", str(binary)]
        subprocess.run(command, check=True)
        subprocess.run([str(binary)], env=env, check=True, timeout=10)


if __name__ == "__main__":
    main()
