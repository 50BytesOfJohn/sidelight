"""Only complete, verified uploads may become a public Sparkle update."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PublishReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.work = Path(self.directory.name)
        self.out = self.work / "release"
        self.out.mkdir()
        self.notes = self.work / "notes.md"
        self.notes.write_text("## Bug fixes\n\n* Fix panel flicker (#12)\n")
        self.assets = []
        for name in ["Sidelight-0.2.0.dmg", "Sidelight-0.2.0.dmg.sha256", "appcast.xml"]:
            path = self.out / name
            path.write_bytes(name.encode())
            self.assets.append({
                "name": name, "size": path.stat().st_size, "state": "uploaded",
                "digest": "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest(),
            })
        self.log = self.work / "calls.jsonl"
        self.uploaded = self.work / "uploaded.json"
        self.body = self.work / "body.md"
        fake_gh = self.work / "gh"
        fake_gh.write_text('''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
with open(os.environ['GH_TEST_LOG'], 'a') as log:
    log.write(json.dumps(args) + '\\n')
if args[0] == 'api':
    print(os.environ['GH_TEST_EXISTING'])
elif args[:2] == ['release', 'view']:
    print(Path(os.environ['GH_TEST_UPLOADED']).read_text())
else:
    if '--notes-file' in args:
        source = Path(args[args.index('--notes-file') + 1])
        Path(os.environ['GH_TEST_BODY']).write_text(source.read_text())
    if args[1] == os.environ.get('GH_TEST_FAIL'):
        sys.exit(1)
''')
        fake_gh.chmod(0o755)

    def run_publish(self, existing="", fail="", assets=None):
        self.uploaded.write_text(json.dumps({
            "isDraft": True, "assets": self.assets if assets is None else assets,
        }))
        env = dict(os.environ, PATH=str(self.work) + os.pathsep + os.environ["PATH"],
                   GITHUB_REPOSITORY="owner/repo", GH_TEST_LOG=str(self.log),
                   GH_TEST_UPLOADED=str(self.uploaded), GH_TEST_BODY=str(self.body),
                   GH_TEST_EXISTING=existing, GH_TEST_FAIL=fail)
        return subprocess.run(["bash", str(ROOT / "scripts/publish-release.sh"),
                               "0.2.0", str(self.notes), str(self.out)],
                              env=env, text=True, capture_output=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_unpublished(self):
        self.assertFalse(any("--draft=false" in call for call in self.calls()))

    def test_new_release_is_staged_verified_and_published(self):
        result = self.run_publish()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual([call[:2] for call in calls[1:]],
                         [["release", "create"], ["release", "view"], ["release", "edit"]])
        self.assertIn("--draft", calls[1])
        self.assertIn("--verify-tag", calls[1])
        self.assertIn("--draft=false", calls[-1])
        self.assertIn("--latest", calls[-1])
        self.assertIn(self.notes.read_text(), self.body.read_text())
        self.assertIn("Sidelight-0.2.0.dmg", self.body.read_text())

    def test_draft_retry_uploads_everything_before_publishing(self):
        result = self.run_publish(existing="true")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        self.assertEqual([call[:2] for call in calls[1:]],
                         [["release", "upload"], ["release", "edit"],
                          ["release", "view"], ["release", "edit"]])
        self.assertIn("--clobber", calls[1])
        self.assertIn("--draft=false", calls[-1])

    def test_published_release_is_never_modified(self):
        result = self.run_publish(existing="false")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already published", result.stderr)
        self.assertEqual(len(self.calls()), 1)

    def test_failed_upload_never_publishes(self):
        for existing, command in [("", "create"), ("true", "upload")]:
            with self.subTest(command=command):
                self.log.unlink(missing_ok=True)
                result = self.run_publish(existing=existing, fail=command)
                self.assertNotEqual(result.returncode, 0)
                self.assert_unpublished()
                self.assertFalse(any(call[:2] == ["release", "view"] for call in self.calls()))

    def test_incomplete_or_corrupt_upload_never_publishes(self):
        incomplete = self.assets[:-1]
        corrupt = [dict(asset) for asset in self.assets]
        corrupt[0]["digest"] = "sha256:" + "0" * 64
        wrong_size = [dict(asset) for asset in self.assets]
        wrong_size[0]["size"] += 1
        pending = [dict(asset) for asset in self.assets]
        pending[0]["state"] = "new"
        for assets in [incomplete, corrupt, wrong_size, pending]:
            with self.subTest(assets=assets):
                self.log.unlink(missing_ok=True)
                result = self.run_publish(assets=assets)
                self.assertNotEqual(result.returncode, 0)
                self.assert_unpublished()


if __name__ == "__main__":
    unittest.main()
