# Contributing

## Prerequisites

| Need | What 1.0.0 was built with (2026-09-04) |
|---|---|
| macOS 14.0 or later to run the app | macOS 26.6.2 on Apple Silicon |
| Xcode | 26.6 (Swift 6.3.3, SDK 26.5) |
| XcodeGen (`brew install xcodegen`) | 2.45.4 at `/opt/homebrew/bin/xcodegen` |
| A code signing identity | `Apple Development: 917762034141 (XB7X3VP977)`, team `Z6SX8L9HA7` |
| `gh` CLI | Releases only |

`project.yml` hard-codes the maintainer's signing identity and team. If you do not hold that certificate, pass your own on the command line (`xcodebuild ... CODE_SIGN_IDENTITY="..." DEVELOPMENT_TEAM=...`). The team ID is the certificate's OU, not the suffix in the identity name. The plan documents an ad-hoc fallback (`CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO`) that re-prompts for notification permission after every rebuild; it was not exercised in the 1.0.0 build.

## First build

The checkout may live in iCloud Drive and its path contains spaces: quote every path, and keep DerivedData outside iCloud (the scripts default to `~/Library/Developer/Xcode/DerivedData/InternetSpeedReader`).

```bash
cd "/path/to/internet-speed-reader"
xcodegen generate --spec project.yml      # the .xcodeproj is git-ignored; regenerate after editing project.yml
xcodebuild -project InternetSpeedReader.xcodeproj -scheme InternetSpeedReader \
  -configuration Release \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/InternetSpeedReader" build
```

Opening the generated `InternetSpeedReader.xcodeproj` in Xcode works too. Edit `project.yml`, never the generated project.

## Running tests

```bash
xcodebuild -project InternetSpeedReader.xcodeproj -scheme InternetSpeedReader \
  -destination 'platform=macOS' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/InternetSpeedReader" test
```

75 Swift Testing tests in 16 suites under `Tests/SpeedCoreTests/`. They depend only on `SpeedCore`, use no network and no test host, so they never launch the menu bar app. Keep it that way: a test that needs the network, a bundle or AppKit is a manual verification step, not a unit test. Inject a `TimeSource` (see `FastClock` in `Tests/SpeedCoreTests/OutageEngineTests.swift`) instead of sleeping.

## Installing a dev build

```bash
./scripts/install.sh      # regenerate, build Release, quit the running copy, ditto to /Applications, codesign --verify, open
./scripts/uninstall.sh    # quit, deregister the login item, remove the app, Application Support, Caches and defaults
```

Always run the app as the installed `.app`. `swift run` or the bare binary crashes in `UNUserNotificationCenter`. The notification permission prompt on first launch is the sign that the bundle and signature are right. `LoginItemManager` only registers from `/Applications`, and `AppCoordinator` re-applies the launch-at-login preference on every launch, so a reinstall does not lose it.

## Commit messages

Every commit on the 1.0.0 branch follows this shape; match it.

- Subject: one line in the imperative, no trailing period. Examples from `git log`: `Re-register the login item on every launch, not just the first`, `M4-M5: outage detection, the durable ledger and drop/restore banners`.
- Body: plain prose that explains why the change exists and what was verified, with the check spelled out (for example: "unregister, reinstall, launch, status reads enabled; reinstall again, status still reads enabled").
- Trailer: `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>` when Claude co-wrote the change. (Six of the eight 1.0.0 commits use this; the last two, `6fe1910` and `94203e0`, carry `Claude Fable 5.1` instead.)

## Pull requests

Work on a branch and open a PR into `main`. The description must carry verification evidence, not a promise: the unit test count, and for anything touching measurement or the network, numbers from a live run against something independent (speed.cloudflare.com in a browser, a real file download compared with the interface counters, `--login-status` after a reinstall). If you change a rule the plan states, say so in the PR and add the deviation to `docs/DECISIONS.md`; the code is the source of truth, the plan is history. Alert sounds, scheduled tests, a global hotkey, auto-update and notarisation are deliberate v1 exclusions; open an issue before adding one.

## Where to ask

Open an issue at https://github.com/Srimi1/Internet-speed-reader/issues. Read `CLAUDE.md` for the operational summary and `docs/ARCHITECTURE.md` for how the pieces fit before proposing structural changes.
