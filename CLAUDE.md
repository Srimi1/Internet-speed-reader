# CLAUDE.md

Read this first. It is the operational map for Internet Speed Reader. Deeper detail lives in `docs/ARCHITECTURE.md` (how the pieces fit) and `docs/DECISIONS.md` (why they are that way).

## What this is

A macOS menu bar agent (Swift 6, AppKit + SwiftUI, XcodeGen, deployment target macOS 14.0) that shows live link-layer throughput from kernel interface counters, detects internet outages with an active HTTP probe and posts silent banners, and runs an on-demand speed test against Cloudflare's public endpoints with Apple's `networkQuality` as an optional second engine.
Version 1.0.0 shipped on 2026-09-04 as a development-signed, non-notarised DMG. Bundle identifier `com.srimi.internetspeedreader`; it never changes because notifications, the login item and defaults all key off it.

## Commands

The checkout lives in iCloud Drive and its path contains spaces: quote every path. DerivedData must stay outside iCloud at `~/Library/Developer/Xcode/DerivedData/InternetSpeedReader`; the scripts default to that via `DERIVED_DATA`.

| Task | Command |
|---|---|
| Regenerate the Xcode project (git-ignored, always regenerate after editing `project.yml`) | `xcodegen generate --spec project.yml` |
| Build Release | `xcodebuild -project InternetSpeedReader.xcodeproj -scheme InternetSpeedReader -configuration Release -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/InternetSpeedReader" build` |
| Unit tests (75 tests, 16 suites, no network, no test host) | `xcodebuild -project InternetSpeedReader.xcodeproj -scheme InternetSpeedReader -destination 'platform=macOS' -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/InternetSpeedReader" test` |
| Build Release, install to `/Applications`, verify signature, launch | `./scripts/install.sh` |
| Build the DMG into `dist/` (git-ignored) | `./scripts/make-dmg.sh` |
| Remove the app, its data, prefs and login item | `./scripts/uninstall.sh` |
| Login item state of the installed copy | `/Applications/InternetSpeedReader.app/Contents/MacOS/InternetSpeedReader --login-status` |

The scheme's test action lists only `SpeedCoreTests`. Run the app only as the installed `.app` bundle (see Traps).

## Layout

| Path | Holds |
|---|---|
| `project.yml` | The only project definition. Targets: `SpeedCore` (static library, nonisolated), `InternetSpeedReader` (app, MainActor), `SpeedCoreTests` (depends on SpeedCore only). |
| `Sources/SpeedCore/Counters/` | `SysctlCounterReader` (`NET_RT_IFLIST2`, 64-bit `if_data64`), `RouteMessageParser`, `ThroughputCalculator`, `LiveThroughputMonitor`, `ActiveDirectionSelector`. |
| `Sources/SpeedCore/Path/` | `NWPathSource` (wraps `NWPathMonitor`), `PathSnapshot` and the pure `ActiveInterfaceSelector` (dedupes `en0` by index, drops `lo0`/`awdl0`/`llw0`/`anpi*`/`bridge0`/`ap1`/`gif0`/`stf0`, physical beats tunnel). |
| `Sources/SpeedCore/Outage/` | `ConnectivityStateMachine` (pure struct, no I/O), `OutageEngine` (actor), `OutageLedger`, `OutageRecord`. |
| `Sources/SpeedCore/Probe/` | `HTTPProber`: gstatic `generate_204` primary, `captive.apple.com` fallback, one shared 3 s round budget. |
| `Sources/SpeedCore/SpeedTest/Cloudflare/` | `CloudflareSpeedTest` actor, `DownloadStream`, `ChunkLadder`, `UploadFixture`, `ResponseValidator`, `ServerTiming`, `CloudflareMeta`, `CloudflareEndpoints`. |
| `Sources/SpeedCore/Apple/` | `NetworkQualityRunner` and the all-optional `NetworkQualityReport`. |
| `Sources/SpeedCore/Support/` | `TimeSource`, `withDeadline`, `SpeedFormatter`, `AtomicJSONStore`, `RingBuffer`, `Log`, `AppPaths`. |
| `Sources/App/` | `AppDelegate`, `AppCoordinator` (composition root), `StatusBar/`, `Popover/`, `Settings/`, `NotificationService`, `LoginItemManager`, `PowerPolicy`, `SpeedTestController`. |
| `Tests/SpeedCoreTests/`, `scripts/`, `Support/Info.plist` | Swift Testing suites; install, DMG and uninstall scripts; the plist `project.yml` points at. |

## Conventions that must hold

- `SpeedCore` is nonisolated (`SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`) and UI-free. It imports only Foundation, Network and os. Never import AppKit or SwiftUI there. The app target defaults to MainActor.
- Tests never touch the network and there is no `TEST_HOST`. `SpeedCoreTests` links SpeedCore only. Running tests must never launch the menu bar agent.
- Every timing rule takes an injected `TimeSource` (`Sources/SpeedCore/Support/TimeSource.swift`). `LiveThroughputMonitor`, `OutageEngine`, `HTTPProber`, `CloudflareSpeedTest` and `SliceSampler` all accept one. Never use `Date` for elapsed time; it moves when the clock is corrected.
- Every network call has a deadline: `withDeadline` (`Sources/SpeedCore/Support/Deadline.swift`) or an explicit `URLSession` resource timeout. URLSession and NWConnection can stay silent forever on a blackholed route (measured: 192.0.2.1 fails only via the 3 s deadline, at 3003 to 3006 ms).
- Every rate divides bytes by measured elapsed time, never by the nominal tick interval (`ThroughputCalculator` in `Sources/SpeedCore/Counters/ThroughputSampler.swift`, `SliceSampler` in `CloudflareSpeedTest.swift`). Speed test throughput is one shared `ByteLedger` per phase over phase elapsed time, never an average of per-request rates.
- A download response that is not `application/octet-stream` of exactly the requested length is `.intercepted` and aborts the test. An upload counts only when `cf-meta-upload-bytes` equals what was sent (`ResponseValidator.swift`).
- Comments say why and cite the failure that motivated the rule. Keep that habit.

## Traps that cost real time

Each of these was hit during the 1.0.0 build. The fix is what is in the tree now.

- `URLSession.data(for:delegate:)` never calls `didReceive data` on a task-scoped delegate. Download read 0.0 Mbps while upload worked. Fix: `DownloadStream` uses a session-level delegate.
- Staging the DMG inside iCloud Drive baked `com.apple.fileprovider.fpfs#P` and `com.apple.FinderInfo` xattrs into the image, and `codesign --verify` on the installed app failed with "resource fork, Finder information, or similar detritus not allowed". Fix in `scripts/make-dmg.sh`: stage in `mktemp` outside iCloud, `ditto --noextattr --noqtn`, `xattr -cr`, re-sign.
- `DEVELOPMENT_TEAM` is the certificate's OU, `Z6SX8L9HA7`, not the `XB7X3VP977` suffix in the identity name. The research assumed the suffix and was wrong.
- `ENABLE_USER_SCRIPT_SANDBOXING: YES` blocked the static library's ObjC header copy phase. Fix: `SWIFT_INSTALL_OBJC_HEADER: NO` and an empty `SWIFT_OBJC_INTERFACE_HEADER_NAME` on `SpeedCore`.
- `NumberFormatter` rounds half-even by default: 84.25 rendered as "84.2". At 10 Gbps and above a decimal made a six-character string that broke the fixed status item width. Fix in `SpeedFormatter.bar`: `.halfUp`, integer gigabits from 10G.
- First-run-only `SMAppService` registration read `.notFound` after the next reinstall, because the background task database records the bundle that was replaced. Fix: `AppCoordinator.reconcileLaunchAtLogin()` re-applies the `launchAtLoginWanted` preference (default true) on every launch. Verified enabled across two reinstalls.
- A test builder once emitted a route message shorter than its own header. The kernel never does that. It was a test bug, not a `RouteMessageParser` bug; check the fixture before the parser.
- Never run via `swift run` or the bare binary. `UNUserNotificationCenter` throws `NSInternalInconsistencyException` without a bundle, and `try` cannot catch it. Install and run the `.app`.
- `SWIFT_DEFAULT_ACTOR_ISOLATION` never appears in the xcodebuild log. It was proven empirically: a synchronous call to a `@MainActor` function compiles in the app target and fails in SpeedCore with "call to main actor-isolated global function in a synchronous nonisolated context".
- SwiftUI `MenuBarExtra` is deliberately not used. Its label is limited to text or text+image, its window cannot be dismissed programmatically, and it has no right-click. `StatusItemController` owns an `NSStatusItem` with a custom `NSView` and an `NSPopover`.
- `/meta` on speed.cloudflare.com returns 403 with `{}` unless a `Referer` or `Origin` header is sent, which silently blanks the ISP. `CloudflareEndpoints.metaRequest()` sets both.
- `__up` ignores `bytes=` in the query string and returns 200 for an empty body. Upload must send a real body: the app posts file-backed fixtures with an explicit `Content-Length` and trusts only `cf-meta-upload-bytes`.
- `__down` rejects requests above 50 MiB (`ChunkLadder.maxBytes = 52_428_800`) with a 403 whose body is one byte. `ResponseValidator` maps that to `.byteCapExceeded`; it looks like a network failure otherwise.
- The Apple binary is `/usr/bin/networkQuality`, camelCase. The lowercase path only resolves on a case-insensitive volume. `-M` is a soft cap; `NetworkQualityRunner` enforces a hard kill.
- App Nap throttles timers regardless of the API used. `AppCoordinator.beginActivity()` is the primary opt-out, `LSAppNapIsDisabled` in Info.plist the backup, and dividing by measured time means throttling degrades cadence, not correctness. Gaps over 5 s rebaseline (`ThroughputCalculator.staleGapSeconds`).
- Of the 10 logging calls, 5 are `Logger.error` and 5 are `Logger.info` or `Logger.debug`. `log show` and `log stream` hide info-level messages unless you pass `--info`. Subsystem `com.srimi.internetspeedreader`, categories `live`, `outage`, `speedtest`, `app`.
- speed.cloudflare.com negotiates HTTP/1.1 only today. One `URLSession` per stream with `httpMaximumConnectionsPerHost = 1` keeps N streams as N connections if that changes; the negotiated protocol is stored in `SpeedTestResult.networkProtocol` so a change is visible.

## Decisions and the code-beats-plan rule

Design decisions and their reasons are recorded in `docs/DECISIONS.md`. The approved plan (`~/.claude/plans/okla-i-want-to-twinkly-nygaard.md`) is history, not authority: where the plan and the code disagree, the code wins, and the disagreement is written down as a deviation. Deviations already in the tree:

| Plan said | Code does |
|---|---|
| `DEVELOPMENT_TEAM: XB7X3VP977` | `Z6SX8L9HA7` (the certificate OU) |
| Stage the DMG in `build/dmg`, HFS+ image | `mktemp` outside iCloud, APFS image |
| `AppleISPLookup` in `Sources/SpeedCore/Apple/` | Does not exist; ISP comes from Cloudflare `/meta` only |
| 403/429 backoff of 15 min, 1 h, 6 h | Flat 15 minutes (`SpeedTestController.fail`) |
| Loaded latency sampled during throughput phases | `downloadLoadedLatencyMs` / `uploadLoadedLatencyMs` exist on `SpeedTestResult` but nothing sets them |
| Download nonce `&r=<uuid>` | `&isr=<stream>-<iteration>` |

## Out of scope for v1

| Item | Why |
|---|---|
| Notarisation | Needs a paid Developer ID certificate; only an Apple Development identity exists on the host. First launch on another Mac needs right-click Open or `xattr -dr com.apple.quarantine`. |
| Scheduled tests | Keeps Cloudflare exposure and data usage bounded. Tests are on demand with 30 s spacing (`SpeedTestController.minimumSpacing`). |
| Global hotkey | User decision for v1. The research names Carbon `RegisterEventHotKey` as the route that needs no Accessibility grant. |
| Sparkle auto-update | Per the research, Sparkle needs a Developer ID signature plus an EdDSA key; development or ad-hoc signing breaks it. |
| Floating panel | The transient `NSPopover` is enough: a running test continues when it closes, and the result is waiting the next time the panel is opened. Automatic reopen is not wired — `AppSettings.reopenPanelOnFinish` (default true) and `StatusItemController.reopenPanelForResult()` both exist, but nothing calls the method. A non-activating `NSPanel` is the documented upgrade. |
| Sound on alerts | User decision. `NotificationService` requests `.alert` only and sets `content.sound = nil`. |

## Release procedure

1. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `project.yml`. `make-dmg.sh` reads the version from there to name the image.
2. `./scripts/install.sh`, then check the installed app by hand: status item visible, notification prompt appears on first launch, one full speed test, `--login-status` reads enabled.
3. `./scripts/make-dmg.sh`. It regenerates, builds Release, stages outside iCloud, strips xattrs, signs with `--options runtime`, runs `codesign --verify --strict`, creates and verifies the image, signs it, and prints size and SHA-256.
4. Merge the branch into `main`, tag `vX.Y.Z`, then `gh release create vX.Y.Z dist/InternetSpeedReader-X.Y.Z.dmg` with the SHA-256 and the Gatekeeper workaround in the notes. `dist/` is git-ignored; the DMG lives only on the release.

1.0.0 went out this way on 2026-09-04: PR #1 merged as `d0ee6db`, tag `v1.0.0`, `InternetSpeedReader-1.0.0.dmg` (1.5 MB, 1,564,806 bytes, SHA-256 `4b11408d3d5d5c8e9d99d45311e8f3eb874048346fe0228d3e9609e353282f46`).
