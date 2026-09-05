#!/usr/bin/env python3
"""Check publication candidates and Git history without printing secret values.

Requires Gitleaks 8.30.1+. Ignored local files are intentionally not published or
copied. Tracked files remain checked even if a new .gitignore rule matches them.
This is defense in depth, not a guarantee that arbitrary personal data is absent.
"""

import argparse
import fnmatch
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile


PRIVATE_NAMES = {
    ".env", ".netrc", ".npmrc", ".pypirc", "credentials.json",
    "speedtests.json", "outages.json", "preferences.plist",
}
PRIVATE_DIRECTORIES = {
    ".aws", ".azure", ".ssh", ".gnupg", ".config", ".claude", ".codex",
    "xcuserdata", "DerivedData", "backups", "local-verification", "security-reports",
    "__pycache__",
}
PRIVATE_GLOBS = (
    "*.pem", "*.key", "*.p8", "*.p12", "*.pfx", "*.cer", "*.crt",
    "*.mobileprovision", "*.provisionprofile", "*.keychain", "*.keychain-db",
    "*.log", "*.xcresult", "*.xcarchive", "*.trace", "*.crash", "*.ips",
    "*.har", "*.pcap", "*.pcapng", "*.sqlite", "*.sqlite3", "*.db",
    "*.backup", "*.bak", "*.local", "*.local.*", "gitleaks-report.*",
    "*.pyc", "*.pyo", "*.zip", "*.tar", "*.tar.gz", "*.tgz", "*.7z", "*.pkg", "*.dmg",
)
PRIVATE_CONTENT = (
    ("personal home directory", re.compile(r"/Users/(?!runner(?:/|\b))[A-Za-z0-9_.-]+/")),
    ("personal Apple signing identity", re.compile(
        r"(?:Apple Development|Apple Distribution|Developer ID Application):\s*[^\s\"']")),
    ("personal Apple team identifier", re.compile(
        r"DEVELOPMENT_TEAM\s*[:=]\s*[\"']?[A-Z0-9]{10}\b")),
)


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.DEVNULL)


def private_path(name):
    path = PurePosixPath(name)
    base = path.name
    if any(part in PRIVATE_DIRECTORIES for part in path.parts):
        return True
    if any(part.endswith((".app", ".xcarchive", ".xcresult", ".dSYM")) for part in path.parts):
        return True
    if base in PRIVATE_NAMES or any(fnmatch.fnmatchcase(base, item) for item in PRIVATE_GLOBS):
        return True
    if base.startswith(".env.") and base != ".env.example":
        return True
    return base.endswith(".xcconfig") and not base.endswith(".example.xcconfig")


def candidates(repo, staged):
    if staged:
        for entry in git(repo, "ls-files", "--stage", "-z").split(b"\0"):
            if not entry:
                continue
            metadata, raw_name = entry.split(b"\t", 1)
            mode, object_id, stage = metadata.split()
            if stage != b"0":
                raise ValueError("Resolve merge conflicts before scanning.")
            name = raw_name.decode("utf-8")
            # Git stores symlink targets as blob text. Never dereference them.
            yield name, git(repo, "cat-file", "blob", object_id.decode()), mode == b"120000"
    else:
        names = set(git(repo, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0"))
        for raw_name in sorted(names):
            if not raw_name:
                continue
            name = raw_name.decode("utf-8")
            path = repo / name
            if path.is_symlink():
                yield name, b"", True
            elif path.is_file():
                yield name, path.read_bytes(), False


def scan_gitleaks(repo, source, mode, config):
    args = [
        "gitleaks", mode, str(source), "--config", str(config), "--redact=100",
        "--no-banner", "--no-color", "--ignore-gitleaks-allow",
        "--report-format", "json", "--report-path", "-", "--log-level", "error",
    ]
    if mode == "git":
        args += ["--log-opts=--all --full-history"]
    # A repository-provided .gitleaksignore cannot suppress unresolved findings.
    with tempfile.TemporaryDirectory(prefix="isr-security-ignore-") as temporary:
        empty_ignore = Path(temporary) / ".gitleaksignore"
        empty_ignore.touch()
        args += ["--gitleaks-ignore-path", str(empty_ignore)]
        result = subprocess.run(args, cwd=repo, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode not in (0, 1):
        print(f"FAIL: {mode} secret scanner could not complete (exit {result.returncode}).")
        return False
    try:
        findings = json.loads(result.stdout or b"[]")
        if not isinstance(findings, list):
            raise ValueError("invalid report")
    except (ValueError, UnicodeDecodeError):
        print(f"FAIL: {mode} secret scanner returned an invalid report.")
        return False
    if result.returncode or findings:
        print(f"FAIL: {mode} scan found {len(findings)} potential secret(s). Values are suppressed.")
        for finding in findings:
            # Never emit Match, Secret, Author, Email, or a raw scanner error.
            name = finding.get("File", "unknown file")
            try:
                name = str(Path(name).relative_to(source))
            except ValueError:
                pass
            print(f"  {json.dumps(name)}:{finding.get('StartLine', '?')} [{finding.get('RuleID', 'unknown rule')}]")
        return False
    print(f"PASS: {mode} secret scan.")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staged", action="store_true", help="check exactly the complete staged index; no history scan")
    parser.add_argument("--repo", type=Path, default=Path.cwd(), help=argparse.SUPPRESS)
    args = parser.parse_args()
    if not shutil.which("gitleaks"):
        print("FAIL: install Gitleaks first (brew install gitleaks).")
        return 2
    try:
        repo = Path(git(args.repo, "rev-parse", "--show-toplevel").decode().strip())
        if not args.staged and git(repo, "rev-parse", "--is-shallow-repository").strip() == b"true":
            print("FAIL: full-history scanning requires a complete clone; fetch the full history first.")
            return 2
        config = Path(__file__).resolve().parent.parent / ".gitleaks.toml"
        valid = True
        with tempfile.TemporaryDirectory(prefix="isr-security-") as temporary:
            snapshot = Path(temporary)
            for name, data, symlink in candidates(repo, args.staged):
                if symlink or private_path(name):
                    print(f"FAIL: publication contains a private artifact or symlink: {json.dumps(name)}")
                    valid = False
                    continue
                text = data.decode("utf-8", errors="replace")
                for description, pattern in PRIVATE_CONTENT:
                    match = pattern.search(text)
                    if match:
                        line = text.count("\n", 0, match.start()) + 1
                        print(f"FAIL: {json.dumps(name)}:{line}: {description} (value suppressed).")
                        valid = False
                target = snapshot / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            valid = scan_gitleaks(repo, snapshot, "dir", config) and valid
        if not args.staged:
            valid = scan_gitleaks(repo, repo, "git", config) and valid
        if valid:
            print("PASS: publication checks completed. Manually review screenshots, prose and metadata too.")
        return 0 if valid else 1
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        # Error strings can contain filenames or values; never publish them.
        print(f"FAIL: security checks could not complete ({type(error).__name__}).")
        return 2


if __name__ == "__main__":
    sys.exit(main())
