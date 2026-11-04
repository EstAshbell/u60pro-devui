#!/usr/bin/env python3
"""Exercise offline installer transitions in a private filesystem, without hardware."""
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent
MANAGER = REPO / "scripts/ashbell-devui.sh"


def elf(marker):
    data = bytearray(128)
    data[:6] = b"\x7fELF\x02\x01"
    data[18:20] = b"\xb7\x00"
    data[64:64 + len(marker)] = marker.encode()
    return bytes(data)


def archive(entries):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz", format=tarfile.USTAR_FORMAT) as tar:
        for name, content in entries.items():
            info = tarfile.TarInfo(name)
            info.size = len(content)
            info.mode = 0o755 if name.endswith(".sh") else 0o644
            tar.addfile(info, io.BytesIO(content))
    return buffer.getvalue()


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="ashbell-installer-test-", dir="/tmp"))
        self.root = self.temp / "device"
        self.env = {**os.environ, "ASHBELL_TEST_ROOT": str(self.root), "ASHBELL_TEST_MODE": "1"}
        self.devui = self.root / "data/plugins/u60pro-devui"
        self.datad = self.root / "data/plugins/zwrt-datad"
        self.state = self.root / "data/plugins/.ashbell-devui"
        (self.root / "etc/rc.d").mkdir(parents=True)
        (self.root / "etc/rc.local").write_text("#!/bin/sh\necho unrelated\nexit 0\n")
        self.bundle = self.make_bundle("one")

    def tearDown(self):
        shutil.rmtree(self.temp)

    def make_bundle(self, version):
        ui = {name: b"<html>fixture</html>" for name in (
            "style.css", "00-overview.html", "01-signal.html", "02-functions.html", "subpages/settings.html",
            "subpages/wifi.html", "subpages/shellcrash.html", "functions/managed.html")}
        ui["subpages/wifi-control.sh"] = b"#!/bin/sh\nexit 0\n"
        ui["subpages/shellcrash-mode.sh"] = b"#!/bin/sh\nexit 0\n"
        ui["00-overview.html"] = version.encode()
        ui["functions/managed.html"] = ("managed-" + version).encode()
        manifest = {"schema": 1, **{k: {"version": version, "asset": v} for k, v in (
            ("devui", "u60pro-devui-aarch64"), ("datad", "zwrt-datad-aarch64"), ("ui", "ui.tar.gz"))}}
        payload = {"version.json": json.dumps(manifest).encode(), "u60pro-devui-aarch64": elf(version),
                   "zwrt-datad-aarch64": elf(version), "ui.tar.gz": archive(ui),
                   "start.sh": b"#!/bin/sh\nexit 0\n", "ashbell-devui.sh": MANAGER.read_bytes(),
                   "LICENSE": b"MIT license fixture", "NOTICE.md": b"Notice fixture"}
        payload["SHA256SUMS"] = "".join(f"{hashlib.sha256(value).hexdigest()}  {name}\n" for name, value in payload.items()).encode()
        path = self.temp / (version + ".tar.gz")
        path.write_bytes(archive(payload))
        return path

    def run_manager(self, *args, ok=True, **env):
        result = subprocess.run(["sh", str(MANAGER), *map(str, args)], env={**self.env, **env},
                                text=True, errors="replace", capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stderr, "", result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_clean_install_update_and_uninstall(self):
        self.run_manager("install", self.bundle)
        self.assertTrue((self.devui / ".ashbell-owned").is_file())
        self.assertTrue((self.datad / "zwrt-datad").is_file())
        rc = (self.root / "etc/rc.local").read_text()
        self.assertLess(rc.index("ashbell_devui"), rc.index("exit 0"))
        (self.devui / "devui.conf").write_text("theme=dark\n")
        (self.devui / "ui/.lockpin").write_text("fixture-pin")
        (self.devui / "ui/functions/mine.html").write_text("custom")
        (self.devui / "ui/functions/managed.html").write_text("old managed override")
        (self.datad / "auth.token").write_text("fixture-token")
        self.run_manager("update", self.make_bundle("two"))
        self.assertEqual((self.devui / "ui/00-overview.html").read_text(), "two")
        self.assertEqual((self.devui / "devui.conf").read_text(), "theme=dark\n")
        self.assertEqual((self.devui / "ui/.lockpin").read_text(), "fixture-pin")
        self.assertEqual((self.devui / "ui/functions/mine.html").read_text(), "custom")
        self.assertEqual((self.devui / "ui/functions/managed.html").read_text(), "managed-two")
        self.assertEqual((self.datad / "auth.token").read_text(), "fixture-token")
        self.run_manager("rollback")
        self.assertEqual((self.devui / "ui/00-overview.html").read_text(), "one")
        self.run_manager("uninstall")
        self.assertFalse(self.devui.exists())
        self.assertFalse(self.datad.exists())
        self.assertIn("echo unrelated", (self.root / "etc/rc.local").read_text())
        self.assertNotIn("ashbell_devui", (self.root / "etc/rc.local").read_text())
        self.run_manager("rollback")
        self.assertTrue((self.devui / ".ashbell-owned").is_file())
        self.assertTrue((self.state / "baseline").is_file())

    def test_takeover_preserves_old_desktop_and_boot_scripts(self):
        (self.devui / "ui").mkdir(parents=True)
        self.datad.mkdir(parents=True)
        (self.devui / "ui/old.html").write_text("original third party")
        (self.devui / "start-devui.sh").write_text("#!/bin/sh\n")
        (self.datad / "auth.token").write_text("original-token")
        (self.datad / "zwrt-datad").write_bytes(elf("old"))
        boot = self.root / "data/plugins/ufi_tools_boot.sh"
        original = "#!/bin/sh\necho other_plugin\nsh /data/plugins/u60pro-devui/start-devui.sh &\n"
        boot.write_text(original)
        self.run_manager("install", self.bundle)
        self.assertNotIn("start-devui", boot.read_text())
        self.assertIn("other_plugin", boot.read_text())
        self.run_manager("rollback")
        self.assertEqual(boot.read_text(), original)
        self.assertEqual((self.devui / "ui/old.html").read_text(), "original third party")
        self.assertFalse((self.devui / ".ashbell-owned").exists())

    def test_uninstall_retains_shared_backend_latest_state_and_original_hook(self):
        self.devui.mkdir(parents=True)
        self.datad.mkdir(parents=True)
        (self.datad / "zwrt-datad").write_bytes(elf("preexisting"))
        (self.datad / "traffic.json").write_text("old counters")
        rc = self.root / "etc/rc.local"
        rc.write_text("#!/bin/sh\necho unrelated\nsh /data/plugins/zwrt-datad/start-datad.sh & # u60pro_devui_datad\nexit 0\n")
        self.run_manager("install", self.bundle)
        (self.datad / "traffic.json").write_text("latest counters")
        self.run_manager("uninstall")
        self.assertEqual((self.datad / "traffic.json").read_text(), "latest counters")
        self.assertIn("start-datad.sh", rc.read_text())
        self.assertNotIn("ashbell_devui", rc.read_text())
        self.assertFalse(self.devui.exists())

    def test_autostart_off_and_on_preserve_shared_backend_other_plugins_and_settings(self):
        self.datad.mkdir(parents=True)
        (self.datad / "traffic.json").write_text("shared counters")
        rc = self.root / "etc/rc.local"
        rc.write_text("#!/bin/sh\necho unrelated\nsh /data/plugins/zwrt-datad/start-datad.sh & # u60pro_devui_datad\nexit 0\n")
        boot = self.root / "data/plugins/ufi_tools_boot.sh"
        boot.write_text("#!/bin/sh\necho another_plugin\nsh /data/plugins/u60pro-devui/start-devui.sh &\n")
        self.run_manager("install", self.bundle)
        (self.devui / "devui.conf").write_text("keep")
        rc.write_text(rc.read_text().replace("exit 0", "/etc/init.d/u60pro-devui start\nnohup /data/plugins/u60pro-devui/u60pro-devui &\nexit 0"))
        self.run_manager("autostart", "off")
        self.assertNotIn("/etc/init.d/u60pro-devui", rc.read_text())
        self.assertNotIn("/data/plugins/u60pro-devui/u60pro-devui", rc.read_text())
        self.assertNotIn("ashbell_devui", rc.read_text())
        self.assertNotIn("start-devui.sh", boot.read_text())
        self.assertIn("start-datad.sh", rc.read_text())
        self.assertIn("another_plugin", boot.read_text())
        self.assertEqual((self.devui / "devui.conf").read_text(), "keep")
        self.assertEqual((self.datad / "traffic.json").read_text(), "shared counters")
        self.assertIn("autostart=off", self.run_manager("autostart", "status").stdout)
        self.run_manager("update", self.make_bundle("two"))
        self.assertNotIn("# ashbell_devui", rc.read_text())
        self.assertEqual(rc.read_text().count("start-datad.sh"), 1)
        self.run_manager("autostart", "on")
        self.run_manager("autostart", "on")
        self.assertEqual(rc.read_text().count("# ashbell_devui"), 1)
        self.assertNotIn("start-datad.sh", rc.read_text())
        self.assertIn("autostart=on", self.run_manager("autostart", "status").stdout)

    def test_cleanup_archives_legacy_resources_and_stale_stage_without_touching_userdata(self):
        self.run_manager("install", self.bundle)
        (self.devui / "start-devui.sh").write_text("old launcher")
        (self.devui / "screen-wifi-key.sh").write_text("old helper")
        (self.devui / "bin").mkdir()
        (self.devui / "bin/ifconfig").write_text("old shim")
        (self.devui / ".screen-ui-backup-before").mkdir()
        (self.devui / ".screen-ui-backup-before/keep.txt").write_text("recovery")
        (self.devui / "devui.conf").write_text("settings")
        (self.devui / "ui/.lockpin").write_text("pin")
        (self.devui / "ui/functions/mine.html").write_text("custom")
        (self.datad / "traffic.json").write_text("latest counters")
        stale = self.state / "staging.previous"
        stale.mkdir(); (stale / "temporary").write_text("incomplete")
        self.assertIn("staging_state=unfinished", self.run_manager("status").stdout)
        previous = (self.state / "last-backup").read_text()
        self.run_manager("cleanup")
        for rel in ("start-devui.sh", "screen-wifi-key.sh", "bin/ifconfig", ".screen-ui-backup-before"):
            self.assertFalse((self.devui / rel).exists())
        self.assertEqual((self.devui / "devui.conf").read_text(), "settings")
        self.assertEqual((self.devui / "ui/.lockpin").read_text(), "pin")
        self.assertEqual((self.devui / "ui/functions/mine.html").read_text(), "custom")
        self.assertEqual((self.datad / "traffic.json").read_text(), "latest counters")
        self.assertFalse(stale.exists())
        self.assertEqual((self.state / "last-backup").read_text(), previous)
        self.assertTrue(list((self.state / "backups").glob("cleanup-*/devui/start-devui.sh")))
        after = self.run_manager("status").stdout
        self.assertIn("legacy_resource_count=0", after)
        self.assertIn("staging_state=clear", after)
        self.assertIn("正常备份", after)

    def test_install_archives_old_helpers_and_normal_legacy_backups(self):
        self.devui.mkdir(parents=True)
        (self.devui / "start-devui.sh").write_text("old launcher")
        (self.devui / ".screen-ui-backup-old").mkdir()
        (self.devui / ".screen-ui-backup-old/old.html").write_text("old recovery")
        before = self.run_manager("status").stdout
        self.assertIn("legacy_recovery_archive=.screen-ui-backup-old", before)
        self.run_manager("install", self.bundle)
        self.assertFalse((self.devui / "start-devui.sh").exists())
        self.assertFalse((self.devui / ".screen-ui-backup-old").exists())
        self.assertTrue(list((self.state / "backups").glob("cleanup-*/devui/.screen-ui-backup-old/old.html")))
        self.run_manager("restart")
        self.assertIn("autostart=on", self.run_manager("diagnostics").stdout)
        self.run_manager("rollback")
        self.assertEqual((self.devui / "start-devui.sh").read_text(), "old launcher")

    def test_current_renderer_logs_are_preserved_and_not_residue(self):
        self.run_manager("install", self.bundle)
        expected = {}
        for name in ("plugin-detect.log", "plugin-detect.log.old"):
            expected[name] = "private-runtime-content-" + name
            (self.devui / name).write_text(expected[name])
        before = self.run_manager("status").stdout
        self.assertIn("legacy_resource_count=0", before)
        self.assertNotIn("legacy_resource=plugin-detect", before)
        self.run_manager("cleanup")
        self.run_manager("update", self.make_bundle("two"))
        diagnostic = self.run_manager("diagnostics").stdout
        self.assertIn("legacy_resource_count=0", diagnostic)
        for name, content in expected.items():
            self.assertEqual((self.devui / name).read_text(), content)
            self.assertIn("runtime_log=/data/plugins/u60pro-devui/" + name, diagnostic)
            self.assertNotIn(content, diagnostic)
            self.assertFalse(list((self.state / "backups").glob("cleanup-*/devui/" + name)))

    def test_health_failure_restores_previous_files_and_hooks(self):
        self.run_manager("install", self.bundle)
        before = (self.root / "etc/rc.local").read_bytes()
        result = self.run_manager("update", self.make_bundle("broken"), ok=False, ASHBELL_TEST_HEALTH="fail")
        self.assertIn("恢复备份", result.stderr)
        self.assertEqual((self.devui / "ui/00-overview.html").read_text(), "one")
        self.assertEqual((self.root / "etc/rc.local").read_bytes(), before)
        self.assertFalse((self.state / "lock").exists())

    def test_corruption_and_symlink_archive_fail_before_changes(self):
        self.run_manager("install", self.bundle)
        with tarfile.open(self.bundle) as tar:
            payload = {entry.name: tar.extractfile(entry).read() for entry in tar.getmembers()}
        payload["u60pro-devui-aarch64"] += b"corrupted"
        corrupt = self.temp / "corrupt.tar.gz"
        corrupt.write_bytes(archive(payload))
        self.run_manager("update", corrupt, ok=False)
        self.assertEqual((self.devui / "ui/00-overview.html").read_text(), "one")
        unsafe = self.temp / "unsafe.tar.gz"
        with tarfile.open(unsafe, "w:gz") as tar:
            entry = tarfile.TarInfo("link"); entry.type = tarfile.SYMTYPE; entry.linkname = "/etc/rc.local"; tar.addfile(entry)
        self.run_manager("update", unsafe, ok=False)
        self.assertEqual((self.devui / "ui/00-overview.html").read_text(), "one")

    def test_update_requires_ownership_and_uninstall_does_not_delete_other_desktop(self):
        self.run_manager("update", self.bundle, ok=False)
        self.devui.mkdir(parents=True)
        (self.devui / "third-party.txt").write_text("keep")
        self.run_manager("uninstall", ok=False)
        self.assertEqual((self.devui / "third-party.txt").read_text(), "keep")

    def test_embedded_plugin_matches_manager(self):
        text = (REPO / "integrations/ufi-tools/Ashbell桌面管理.html").read_text()
        encoded = text.split("const managerBase64 = '", 1)[1].split("'", 1)[0]
        self.assertEqual(base64.b64decode(encoded), MANAGER.read_bytes())


if __name__ == "__main__":
    unittest.main()
