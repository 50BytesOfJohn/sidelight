"""Verify a fixed Ed25519 test vector and reject corrupted archives and keys."""

import base64
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
# Derived once from an all-zero test seed; unrelated to Sidelight's real signing key.
PUBLIC_KEY = "O2onvM62pC1io6jQKm8Nc2UyFXcd4kOmOsBIoYtZ2ik="
SIGNATURE = "gHUwaChi3YGUiWqcXICyH/S5qDaD30SM2Fqdf7zBo8S3PGj8fIQr6Pj31U1amIsucuofBdLlvaPbUltib73QCw=="


class UpdateSignatureTests(unittest.TestCase):
    def verify(self, data=b"test archive", key=PUBLIC_KEY):
        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / "archive.dmg"
            archive.write_bytes(data)
            return subprocess.run(
                ["xcrun", "swift", "-warnings-as-errors", "scripts/verify-update.swift",
                 key, SIGNATURE, str(archive)],
                cwd=ROOT, capture_output=True, text=True)

    def test_accepts_valid_signature(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_corrupted_archive(self):
        self.assertNotEqual(self.verify(data=b"test archivE").returncode, 0)

    def test_rejects_wrong_public_key(self):
        key = base64.b64encode(bytes(32)).decode()
        self.assertNotEqual(self.verify(key=key).returncode, 0)


if __name__ == "__main__":
    unittest.main()
