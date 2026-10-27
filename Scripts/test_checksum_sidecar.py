from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("write-checksum-sidecar.sh").resolve()
TEST_ROOT = Path(os.environ.get("RUNNER_TEMP") or os.environ.get("TMPDIR") or "")
if not TEST_ROOT.is_absolute() or not TEST_ROOT.is_dir():
    raise SystemExit("Set RUNNER_TEMP or TMPDIR to an existing scratch directory for tests")
PACKAGED_ZIP = Path(sys.argv.pop(1)).resolve() if len(sys.argv) > 1 else None


class ChecksumSidecarTests(unittest.TestCase):
    def verify_downloaded_pair(self, zip_path: Path, sidecar: Path, destination: Path) -> None:
        self.assertTrue(zip_path.is_file(), f"ZIP is missing: {zip_path}")
        self.assertTrue(sidecar.is_file(), f"sidecar is missing: {sidecar}")
        fields = sidecar.read_text(encoding="utf-8").split()
        self.assertEqual(fields, [hashlib.sha256(zip_path.read_bytes()).hexdigest(), zip_path.name])

        downloaded_pair = destination / "downloaded-together"
        downloaded_pair.mkdir()
        shutil.copy2(zip_path, downloaded_pair / zip_path.name)
        shutil.copy2(sidecar, downloaded_pair / sidecar.name)
        checker = shutil.which("sha256sum")
        if checker:
            command = [checker, "-c", sidecar.name]
        else:
            checker = shutil.which("shasum")
            self.assertIsNotNone(checker, "sha256sum or shasum must be available")
            command = [checker, "-a", "256", "-c", sidecar.name]
        verification = subprocess.run(
            command,
            cwd=downloaded_pair,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(verification.returncode, 0, verification.stdout + verification.stderr)

    def test_generated_sidecar_works_after_zip_and_sidecar_are_downloaded_together(self) -> None:
        with tempfile.TemporaryDirectory(dir=TEST_ROOT) as temporary:
            root = Path(temporary)
            dist = root / "dist"
            dist.mkdir()
            zip_path = dist / "EchoNyla-3.1.1.zip"
            zip_path.write_bytes(b"test archive payload\n")

            result = subprocess.run(
                ["bash", str(SCRIPT), f"dist/{zip_path.name}"],
                cwd=root,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            sidecar = zip_path.with_suffix(zip_path.suffix + ".sha256")
            self.verify_downloaded_pair(zip_path, sidecar, root)

    def test_packaged_sidecar_works_after_zip_and_sidecar_are_downloaded_together(self) -> None:
        if PACKAGED_ZIP is None:
            self.skipTest("no packaged ZIP argument supplied")
        sidecar = PACKAGED_ZIP.with_suffix(PACKAGED_ZIP.suffix + ".sha256")
        with tempfile.TemporaryDirectory(dir=TEST_ROOT) as temporary:
            self.verify_downloaded_pair(PACKAGED_ZIP, sidecar, Path(temporary))


if __name__ == "__main__":
    unittest.main(verbosity=2)
