"""Exercise the standalone CPU helper against a temporary cpufreq tree."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "ui/functions/cpuctl.sh"


class CPUControlTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ashbell-cpu-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.policy = self.make_policy("policy0")

    def make_policy(self, name, governors="powersave schedutil performance"):
        policy = self.root / name
        policy.mkdir()
        values = {
            "scaling_available_governors": governors,
            "scaling_governor": "schedutil",
            "scaling_cur_freq": "900000",
            "scaling_min_freq": "300000",
            "scaling_max_freq": "2208000",
            "cpuinfo_min_freq": "300000",
            "cpuinfo_max_freq": "2208000",
        }
        for field, value in values.items():
            (policy / field).write_text(value + "\n")
        return policy

    def run_helper(self, argument, root=None):
        environment = dict(os.environ, U60_CPU_SYS=str(root or self.root))
        return subprocess.run(
            ["/bin/sh", str(SCRIPT), argument], env=environment,
            text=True, capture_output=True, timeout=10,
        )

    def value(self, field):
        return (self.policy / field).read_text().strip()

    def test_modes_restore_full_range_after_highest_frequency(self):
        expected_governors = {
            "extreme": "performance", "balance": "schedutil",
            "powersave": "powersave", "performance": "performance",
        }
        for mode, governor in expected_governors.items():
            with self.subTest(mode=mode):
                result = self.run_helper(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("CPU_MODE=" + mode, result.stdout)
                self.assertEqual(self.value("scaling_governor"), governor)
                self.assertEqual(self.value("scaling_max_freq"), "2208000")
                self.assertEqual(self.value("scaling_min_freq"),
                                 "2208000" if mode == "extreme" else "300000")

    def test_status_converts_khz_to_mhz_without_changing_settings(self):
        before = {p.name: p.read_bytes() for p in self.policy.iterdir()}
        result = self.run_helper("status")
        self.assertEqual(result.returncode, 0)
        self.assertIn("CPU_CUR=900", result.stdout)
        self.assertIn("CPU_MAX=2208", result.stdout)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.policy.iterdir()})

    def test_unsupported_second_policy_does_not_change_first(self):
        self.make_policy("policy4", governors="schedutil")
        result = self.run_helper("performance")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("不支持此模式", result.stderr)
        self.assertEqual(self.value("scaling_governor"), "schedutil")

    def test_unknown_governor_is_custom_instead_of_balance(self):
        (self.policy / "scaling_governor").write_text("userspace\n")
        result = self.run_helper("status")
        self.assertEqual(result.returncode, 0)
        self.assertIn("CPU_MODE=custom", result.stdout)
        self.assertIn("CPU_GOV=userspace", result.stdout)
        self.assertEqual(self.value("scaling_governor"), "userspace")

    def test_only_known_adaptive_governors_report_balance(self):
        for governor in ["schedutil", "ondemand", "interactive", "conservative"]:
            with self.subTest(governor=governor):
                (self.policy / "scaling_governor").write_text(governor + "\n")
                result = self.run_helper("status")
                self.assertEqual(result.returncode, 0)
                self.assertIn("CPU_MODE=balance", result.stdout)

    def test_missing_interface_and_invalid_command_are_failures(self):
        result = self.run_helper("performance", self.root / "missing")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CPU_INST=0", result.stdout)
        self.assertEqual(self.run_helper("something-else").returncode, 2)


if __name__ == "__main__":
    unittest.main()
