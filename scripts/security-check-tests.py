#!/usr/bin/env python3
"""Exercise publication protection using temporary, deliberately fake data."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("security-check.py")
SPEC = importlib.util.spec_from_file_location("security_check", SCRIPT)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class SecurityChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="isr-security-test-")
        self.repo = Path(self.temporary.name)
        self.git("init", "-q")
        (self.repo / "README.md").write_text("A safe synthetic project.\n")
        self.git("add", ".")
        self.commit()

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def commit(self):
        self.git("-c", "user.name=Security Check", "-c", "user.email=checks@example.invalid",
                 "commit", "-qm", "Synthetic test fixture")

    def scan(self, *args):
        return subprocess.run(["python3", str(SCRIPT), "--repo", str(self.repo), *args],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def fake_secret(self):
        # Construct at runtime: no reusable credential is stored in this repository.
        return "gh" + "p_" + "A7b8C9d0E1f2G3h4I5j6K7l8M9n0P1q2R3s4"

    def test_clean_repository(self):
        self.assertEqual(self.scan().returncode, 0)

    def test_untracked_secret_is_detected_without_disclosing_it(self):
        secret = self.fake_secret()
        (self.repo / "sample.txt").write_text(secret)
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(secret.encode(), result.stdout + result.stderr)

    def test_deleted_secret_is_detected_in_history(self):
        (self.repo / "sample.txt").write_text(self.fake_secret())
        self.git("add", ".")
        self.commit()
        self.git("rm", "sample.txt")
        self.commit()
        self.assertEqual(self.scan().returncode, 1)

    def test_staged_secret_cannot_be_hidden_by_an_unstaged_edit(self):
        (self.repo / "sample.txt").write_text(self.fake_secret())
        self.git("add", ".")
        (self.repo / "sample.txt").write_text("Safe unstaged replacement")
        self.assertEqual(self.scan("--staged").returncode, 1)

    def test_ignored_local_file_is_not_published_but_forced_tracking_fails(self):
        (self.repo / ".gitignore").write_text(".env\n")
        (self.repo / ".env").write_text("A synthetic local setting")
        self.assertEqual(self.scan().returncode, 0)
        self.git("add", "-f", ".env")
        self.assertEqual(self.scan().returncode, 1)

    def test_machine_path_is_rejected_without_disclosing_it(self):
        personal = "/" + "Users" + "/synthetic-person/private-document"
        (self.repo / "sample.txt").write_text(personal)
        result = self.scan()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(personal.encode(), result.stdout + result.stderr)

    def test_symlink_is_not_followed(self):
        (self.repo / "linked-file").symlink_to("/nonexistent-private-target")
        self.assertEqual(self.scan().returncode, 1)

    def test_private_artifact_rules_preserve_examples(self):
        for name in (".env.production", "local/signing.p12", "Config/Signing.xcconfig", "data/run.pcap"):
            self.assertTrue(CHECK.private_path(name))
        for name in (".env.example", "Config/Signing.example.xcconfig", "docs/logo.png", "Sources/App.swift"):
            self.assertFalse(CHECK.private_path(name))


if __name__ == "__main__":
    unittest.main()
