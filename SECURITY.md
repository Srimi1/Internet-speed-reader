# Security policy

## Report a vulnerability privately

Use [GitHub private vulnerability reporting](https://github.com/Srimi1/Internet-speed-reader/security/advisories/new).
Include the affected version, impact and minimal reproduction with synthetic data.
Do not put API keys, passwords, personal logs, network captures, private documents
or exploit details in a public issue or pull request. If the private form is
unavailable, ask in a public issue for a private reporting channel without posting
sensitive details. This is a volunteer project; no response deadline is promised.

Security fixes target the current 1.1 release line. Older versions may require an
upgrade. A security report is not permission to test other people's devices or
third-party speed-test infrastructure.

## Data and network boundaries

The live meter reads local interface counters; it does not inspect packet payloads
or identify individual applications. Preferences and test/outage history stay in
the app's local macOS storage unless you choose to share them. There is no project
analytics service or account/API-key requirement.

Connectivity checks contact public endpoints. Go tests transfer data to Cloudflare,
and the optional Apple Deep Test runs Apple's `networkQuality`. These providers
can observe normal connection metadata, including the public IP address. Passive
traffic monitoring and active network tests therefore have different privacy and
bandwidth effects. See [architecture](docs/ARCHITECTURE.md) for the implemented
endpoints and behavior. macOS notification and login-item permissions are managed
by the operating system.

## Repository defenses

- Ignore rules exclude local configuration, signing assets, app data and diagnostic
  artifacts. The scanner still rejects private artifacts that were force-added.
- `python3 scripts/security-check.py` checks publishable working files and full
  reachable Git history with Gitleaks, suppressing secret values in its output.
  The optional pre-commit hook checks the staged index before a commit exists.
- CI runs on ordinary pull requests with read-only contents permission, does not
  persist checkout credentials, and uses full-SHA action pins and verified tool
  archive checksums. Builds need no personal certificate; unit tests use no public
  speed-test traffic. No signing key or release token is placed in CI.
- Dependabot proposes GitHub Actions updates. Tool checksums and Xcode versions
  also need deliberate maintenance. Changes to guardrails receive code review.

GitHub secret scanning, push protection, private reporting and branch rules are
repository settings, separate from files in this checkout. Maintainers must verify
that the available protections are enabled and required checks apply to `main`.
Neither these settings nor local scanners can guarantee detection of every secret,
personal detail, screenshot, binary metadata field or private work document.
Review the exact files and release artifacts before publishing.

## If information is accidentally exposed

Revoke or rotate a leaked credential first; deleting a file does not invalidate it.
Privately notify the maintainer and avoid copying the value into more systems.
Remove it from the current tree and coordinate removal from Git history, tags,
release assets, CI logs and attachments where applicable. Rewriting public history
requires coordination because collaborators' clones and forks can retain copies.
For cached views and pull-request references, follow
[GitHub's sensitive-data removal guidance](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository).
Do not hide unresolved findings behind scanner baselines or broad allowlists.
