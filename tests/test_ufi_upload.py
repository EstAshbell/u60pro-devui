#!/usr/bin/env python3
"""Run browser-bridge upload tests using an isolated real installer validator."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import tarfile
import unittest

import test_ashbell_installer as fixture_tests


class UfiUploadTests(unittest.TestCase):
    def test_upload_with_real_validator(self):
        if not shutil.which("node"):
            self.skipTest("Node.js is required for the UFI plugin browser bridge test")
        fixture = fixture_tests.InstallerTests()
        fixture.setUp()
        try:
            with tarfile.open(fixture.bundle) as tar:
                payload = {entry.name: tar.extractfile(entry).read() for entry in tar.getmembers()}
            # Deterministic pseudo-random bytes force several transport chunks.
            payload["u60pro-devui-aarch64"] += b"".join(hashlib.sha256(str(i).encode()).digest() for i in range(4000))
            del payload["SHA256SUMS"]
            payload["SHA256SUMS"] = "".join(f"{hashlib.sha256(value).hexdigest()}  {name}\n" for name, value in payload.items()).encode()
            fixture.bundle.write_bytes(fixture_tests.archive(payload))
            repo = Path(__file__).resolve().parent.parent
            result = subprocess.run(["node", str(repo / "tests/test_ufi_upload.js"),
                                     str(repo / "integrations/ufi-tools/Ashbell桌面管理.html"),
                                     str(fixture.bundle), str(fixture.root)],
                                    text=True, capture_output=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        finally:
            fixture.tearDown()


if __name__ == "__main__":
    unittest.main()
