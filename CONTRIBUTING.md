# Contributing

Internet Speed Reader is a Swift 6 menu bar utility for macOS 14 or later. Changes
should keep background monitoring automatic, distinguish unavailable readings from
measured idle traffic, and avoid saving unverified speed-test results.

## Build and test

Install Xcode 26.6 or later, XcodeGen, and Gitleaks. No API key, account token or
personal signing certificate is needed to build the source or run unit tests.

```bash
brew install xcodegen gitleaks pre-commit
xcodegen generate --spec project.yml
xcodebuild -project InternetSpeedReader.xcodeproj -scheme InternetSpeedReader \
  -configuration Release \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/InternetSpeedReader" \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
xcodebuild -project InternetSpeedReader.xcodeproj -scheme InternetSpeedReader \
  -destination 'platform=macOS' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/InternetSpeedReader" \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test
```

Edit `project.yml`, then regenerate the ignored Xcode project. Quote paths that
contain spaces. Keep DerivedData outside cloud-synced folders. The app uses only
Apple system frameworks; XcodeGen generates the project without fetching app dependencies.

The 125 Swift Testing tests use local doubles, with no public network requests and
no app test host. Keep capacity tests manual: they consume bandwidth and depend on
external services. Inject a clock for elapsed-time logic instead of adding sleeps.

Run the application as an `.app` bundle. `scripts/install.sh` installs a local
build; `scripts/make-dmg.sh` packages it. The uninstall script also removes local
preferences and history, so read it before running it. Ad-hoc signatures support
local development but are not Developer ID signatures or notarization. macOS may
require renewed permissions when replacing development builds. If you use your
own signing identity, keep its configuration and private key outside Git and pass
settings locally. Never commit a certificate, provisioning profile or keychain.

## Before committing

Install the optional local hook once, then review and scan each contribution:

```bash
pre-commit install
python3 scripts/security-check-tests.py
python3 scripts/security-check.py
git diff --cached
```

The hook scans the complete staged index, so an unstaged clean copy cannot conceal
a staged credential. The full check scans tracked and nonignored working files
plus every reachable commit in the local clone. A shallow clone must fetch full
history first. Gitleaks findings suppress values; do not attach raw scanner reports
to public issues. The scanner does not send source or findings to another service.

Do not commit environment files, local signing configuration, logs, application
history, network captures, backups, private work documents or machine diagnostics.
Manually inspect prose and image metadata too: automated patterns cannot identify
all personal information. Replace actual IP addresses, Wi-Fi names, device names,
home directories, account identifiers and employer/customer details with synthetic
examples. `.gitignore` prevents accidental additions; it does not protect tracked
files or remove earlier commits. See [SECURITY.md](SECURITY.md) if something leaked.

Use a privacy-preserving Git author email, such as your GitHub-provided noreply
address, if you do not want your personal email in public commit history.

## Pull requests

Use a branch and open a pull request into `main`. Explain the problem, resulting
behavior, checks actually run and remaining limits. Include manual measurement
results only when relevant, with personal identifiers removed. Match the existing
plain imperative commit style. Do not claim live accuracy from unit tests alone.

Read [CLAUDE.md](CLAUDE.md), [architecture](docs/ARCHITECTURE.md) and
[decisions](docs/DECISIONS.md) before changing core contracts. Keep SpeedCore free
of UI frameworks, use measured monotonic time, and preserve history compatibility.

The CI checks use read-only repository access, SHA-pinned actions, checksum-verified
tool downloads, unsigned builds and offline unit tests. They have no signing
credentials or release secrets and do not install the app on a personal Mac.
Dependabot proposes action updates; maintainers must also review pinned Gitleaks,
XcodeGen and Xcode versions when dependencies change. Never add a secret to make a
fork pull request work, or switch to `pull_request_target` to execute its code.

Ask ordinary product questions in [Issues](https://github.com/Srimi1/Internet-speed-reader/issues).
Report vulnerabilities through the [private security form](https://github.com/Srimi1/Internet-speed-reader/security/advisories/new).
