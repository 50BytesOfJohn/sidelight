"""Keep bad URLs, build numbers and unsigned updates out of releases."""

import base64
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("verify_appcast", ROOT / "scripts/verify-appcast.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.archive = Path(self.directory.name) / "Sidelight-0.1.0.dmg"
        self.archive.write_bytes(b"test archive")
        self.feed = Path(self.directory.name) / "appcast.xml"
        self.repo = "https://github.com/50BytesOfJohn/sidelight"
        self.plist = {
            "CFBundleVersion": "7",
            "CFBundleShortVersionString": "0.1.0",
            "LSMinimumSystemVersion": "26.0",
            "SUPublicEDKey": base64.b64encode(bytes(32)).decode(),
        }
        self.signature = base64.b64encode(bytes(64)).decode()
        self.xml = f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel><item><sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
            <sparkle:version>7</sparkle:version>
            <sparkle:shortVersionString>0.1.0</sparkle:shortVersionString>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <enclosure url="{self.repo}/releases/download/v0.1.0/{self.archive.name}"
            length="12" type="application/octet-stream" sparkle:edSignature="{self.signature}" />
            </item></channel></rss>'''

    def verify(self, xml=None):
        self.feed.write_text(xml or self.xml)
        return verifier.verify_metadata(self.plist, self.archive, self.feed, "0.1.0", self.repo)

    def test_valid_metadata(self):
        self.assertEqual(self.verify(), self.signature)

    def test_rejects_broken_release_metadata(self):
        for old, new in [
            ("releases/download/v0.1.0", "releases/latest/download"),
            ('length="12"', 'length="13"'),
            ('<sparkle:version>7<', '<sparkle:version>6<'),
            ('<sparkle:shortVersionString>0.1.0<', '<sparkle:shortVersionString>0.2.0<'),
            (">26.0<", ">27.0<"),
            (">arm64<", ">x86_64<"),
            (f'sparkle:edSignature="{self.signature}"', ''),
        ]:
            with self.subTest(replacement=new), self.assertRaises(ValueError):
                self.verify(self.xml.replace(old, new))

    def test_rejects_multiple_updates(self):
        with self.assertRaises(ValueError):
            self.verify(self.xml.replace("</channel>", "<item /></channel>"))

    def test_rejects_missing_public_key(self):
        del self.plist["SUPublicEDKey"]
        with self.assertRaises(ValueError):
            self.verify()

    def test_rejects_unsafe_version_before_building(self):
        for version in ["../outside", "0.1.0-beta", "v0.1.0", "01.2.3", "0.1"]:
            with self.subTest(version=version):
                result = subprocess.run(["bash", "scripts/release.sh", version], cwd=ROOT,
                                        text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("version must be a numeric version", result.stderr)


if __name__ == "__main__":
    unittest.main()
