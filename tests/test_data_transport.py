#!/usr/bin/env python3
"""Exercise the merged transport through a real loopback HTTP/SSE server."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
finished = threading.Event()


class Backend(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    state_reads = 0
    posts = []

    def log_message(self, *_args):
        pass

    def respond(self, payload):
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def do_GET(self):
        if self.path == "/events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            # Keep the connection alive. The client must actively reject the
            # malformed snapshots and fetch /state instead of freezing forever.
            self.wfile.write(b"event: state\ndata: not-json\n\n" * 5)
            self.wfile.flush()
            finished.wait(10)
            self.close_connection = True
        elif self.path == "/state":
            Backend.state_reads += 1
            self.respond({
                "battery": {"percent": 40 + Backend.state_reads},
                "system": {"cpu_usage": 12},
                "wlan": {"ssid": "Legacy<&>", "key": "a" * 64,
                         "enc": "psk2", "enabled": 1},
                "timezone": {
                    "offset_minutes": 480, "dst_minutes": 0,
                    "effective_minutes": 480, "label": "UTC+08:00",
                },
                "sim_traffic": {
                    "available": True, "active_sim_id": "test-sim",
                    "sims": [{"id": "test-sim", "slot": 1,
                              "today_bytes": 4294967297, "active": True}],
                },
            })
        elif self.path == "/chart-metrics":
            self.respond({"cpu_usage": 13, "cpu_temp": 42000,
                          "mem_used_pct": 20, "rx_speed": 123,
                          "tx_speed": 45, "battery_temp": 32,
                          "bat_uv": 4000000, "bat_ua": 100000})
        else:
            self.send_error(404)

    def do_POST(self):
        Backend.posts.append((self.path, self.headers.get("Content-Length")))
        self.respond({"ok": True})


PROBE = r'''
#include "data.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
static uint32_t now_ms(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint32_t)(t.tv_sec * 1000 + t.tv_nsec / 1000000);
}
int main(void) {
    devui_data_t state;
    assert(data_backend_init());
    assert(data_refresh(&state) && state.bat_percent == 41);
    assert(strlen(state.wifi_key) == 64 && !strcmp(state.wifi_ssid, "Legacy<&>"));
    assert(state.timezone_available && state.timezone_offset_minutes == 480);
    assert(state.sim_traffic_available && state.sim_traffic_n == 1);
    assert(state.sim_traffic[0].today_bytes == 4294967297ULL);
    int recovered = 0;
    for (int i = 0; i < 100; ++i) {
        data_backend_poll(now_ms());
        data_backend_commit_latest();
        if (data_refresh(&state) && state.bat_percent >= 42) { recovered = 1; break; }
        usleep(10000);
    }
    assert(recovered);
    data_backend_suspend();
    assert(data_refresh(&state) && state.bat_percent == 42);
    assert(data_backend_poll(now_ms()) == 0);
    assert(data_chart_metrics(&state) && state.cpu_usage == 13 && state.rx_speed == 123);
    assert(data_backend_resume());
    assert(data_backend_commit_latest());
    assert(data_refresh(&state) && state.bat_percent == 43);
    char response[256];
    assert(data_backend_request("POST", "/settings/timezone?offset_minutes=480", response, sizeof response) == 200);
    assert(strstr(response, "true"));
    data_backend_close();
    puts("data transport tests passed");
    return 0;
}
'''


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Backend)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="u60-data-test-") as directory:
            probe = Path(directory) / "probe.c"
            binary = Path(directory) / "probe"
            probe.write_text(PROBE)
            command = shlex.split(os.environ.get("CC", "cc")) + [
                "-std=c11", "-D_GNU_SOURCE", "-I", str(ROOT / "include"),
                f"-DDEVUI_BACKEND_PORT={server.server_port}",
                str(probe), str(ROOT / "src/data.c"), str(ROOT / "src/json.c"),
                "-o", str(binary),
            ]
            subprocess.run(command, check=True)
            subprocess.run([str(binary)], check=True, timeout=10)
            assert Backend.state_reads == 3, Backend.state_reads
            assert Backend.posts == [("/settings/timezone?offset_minutes=480", "0")]
    finally:
        finished.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


if __name__ == "__main__":
    main()
