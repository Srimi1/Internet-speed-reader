# Implementation plan and status

This file is the historical record of how Internet Speed Reader v1.0.0 was planned and what actually shipped. It has three parts: a status section that maps each milestone to the commit that delivered it, a list of every place the shipped code differs from the plan, and the approved plan itself, reproduced in full.

Ground truth, in order: the code under `Sources/`, `Tests/`, `project.yml` and `scripts/`; the facts measured during the build on 2026-09-04; then this plan. Where the plan and the code disagree, the code wins, and the "Deviations from plan" section says so.

## Status

### Milestones to commits

The plan defined twelve milestones, M0 to M11, each meant to be one commit on a feature branch. The branch was merged into `main` through PR #1 (merge commit `d0ee6db`) and tagged `v1.0.0`. The commit list below is the order recorded during the build. Milestones were paired into commits where the work overlapped, and M7 and M8 landed before M6 and M9.

| Commit (in branch order) | Milestones delivered | What the commit contains |
|---|---|---|
| `M0: bootstrap XcodeGen project and prove the Swift 6 toolchain` (`7aa518a`) | M0 | `project.yml`, `.gitignore`, `scripts/`, the `SpeedCore`, `InternetSpeedReader` and `SpeedCoreTests` targets. Default actor isolation was proved empirically, not from the build log (see below). |
| `M1-M3 permissions/counters/path/readout` | M1, M2, M3 | `Sources/App/NotificationService.swift`, `Sources/App/LoginItemManager.swift`, `Sources/SpeedCore/Counters/`, `Sources/SpeedCore/Path/`, `Sources/App/StatusBar/`. |
| `M4-M5 outage engine+notifications` | M4, M5 | `Sources/SpeedCore/Outage/`, `Sources/SpeedCore/Probe/ConnectivityProbe.swift`, sleep and wake observers in `Sources/App/AppCoordinator.swift`. |
| `M7-M8 Cloudflare engine` | M7, M8 | `Sources/SpeedCore/SpeedTest/`, including `Cloudflare/CloudflareSpeedTest.swift`, `DownloadStream.swift`, `ByteLedger.swift`, `ThroughputAggregator.swift`, `UploadFixture.swift`. |
| `M6,M9 panel/settings/Apple` | M6, M9 | `Sources/App/Popover/`, `Sources/App/Settings/SettingsView.swift`, `Sources/App/SpeedTestController.swift`, `Sources/SpeedCore/Apple/`. |
| `M10-M11: DMG packaging, README and the 1.0.0 release` | M10, M11 | `scripts/make-dmg.sh` and `README.md`. `scripts/uninstall.sh` already existed from M0 and was last changed by the login re-register fix; the DMG itself is never committed, because `dist/` is git-ignored and the image is attached to the GitHub release. |
| `6fe1910` Show one adaptive number in the menu bar, and launch at login by default | after plan | `Sources/SpeedCore/Counters/ActiveDirectionSelector.swift`, the `adaptive` case in `Sources/App/StatusBar/StatusItemView.swift`, `launchAtLoginWanted` in `Sources/App/AppSettings.swift`. |
| `94203e0` Re-register the login item on every launch, not just the first | after plan | `reconcileLaunchAtLogin()` in `Sources/App/AppCoordinator.swift`. |

Full commit list on `main`, oldest first: `2d96b2b` Initial commit, `7aa518a` M0, `705dd16` M1-M3, `4cc91b7` M4-M5, `bfd3c35` M7-M8, `9ed13a1` M6 and M9, `e7d8433` M10-M11, `6fe1910` adaptive number and login default, `94203e0` login re-register fix, merged as `d0ee6db`.

### Release

| Item | Value |
|---|---|
| Tag | `v1.0.0` |
| Merge | PR #1 into `main`, merge commit `d0ee6db` |
| Artifact | `InternetSpeedReader-1.0.0.dmg`, 1.5 MB (1,564,806 bytes), attached to the GitHub release |
| SHA-256 | `4b11408d3d5d5c8e9d99d45311e8f3eb874048346fe0228d3e9609e353282f46` |
| Signing | `Apple Development: 917762034141 (XB7X3VP977)`, team `Z6SX8L9HA7`, hardened runtime on, not notarised |
| Unit tests | 75 tests in 16 suites, no network, no test host |

### Verification evidence recorded on 2026-09-04

These are the measurements taken during the build. They are the only numbers this document treats as verified.

| Plan check | What was measured |
|---|---|
| M0: isolation flag in the build log | `SWIFT_DEFAULT_ACTOR_ISOLATION` never appears in the `xcodebuild` log. It was proved instead by a probe that calls a `@MainActor` function synchronously: it compiles in the app target and fails in `SpeedCore` with "call to main actor-isolated global function in a synchronous nonisolated context". |
| M1: grants survive reinstall | Launch at login was verified enabled across two reinstalls after the re-register fix. The notification permission prompt appeared from the installed build, which proves the bundle and signature are right. The user had not yet clicked Allow at the time of writing. |
| M2: live meter within about 5 percent of `netstat` | Against a real 50 MiB download: 154.45 Mbps link-layer versus 140.96 Mbps payload, 9.6 percent overhead (57,447,424 interface bytes for 52,428,800 payload bytes in 2.976 s). A harness driving the real `LiveThroughputMonitor` read 88 to 148 Mbps during the transfer and 0.01 Mbps idle. |
| M3: interface selection | `NWPath` returned `en0` twice, once per address family, which is what `ActiveInterfaceSelector` dedupes. A real VPN was not exercised; no fact was recorded. |
| M4: prober timing | Healthy: 216 ms cold, then 46 to 49 ms warm. Blackholed `192.0.2.1`: fails through the deadline at 3003 to 3006 ms against a 3000 ms round budget. |
| M7: ping accuracy | Over 20 samples: raw HTTP median 77.2 ms, minus `Server-Timing` 52.4 ms, `cfL4` `min_rtt` median 46.1 ms, ICMP ping 20 ms, `curl` TCP connect 34 ms. HTTP minus server time tracks the server's TCP RTT within about 6 ms and is the method speed.cloudflare.com itself uses. ICMP reads lower because it takes a different anycast path. |
| M8: throughput | Live run: 176.3 Mbps download (mean 158.7, peak 292.1, 6 streams, 2048 KiB chunks, 205.5 MB), 137.9 Mbps upload (4 streams, 122.7 MB, all server-confirmed via `cf-meta-upload-bytes`), ping 82.8 ms, jitter 15.6 ms, `cfL4` min RTT 32.1 ms, ISP "Bharti Airtel Limited", client Patna, colo Kolkata (CCU), protocol `http/1.1`, wall time 23.6 s. Single 25 MiB stream 120 Mbps; four parallel streams about 160 Mbps summed. |
| M11: DMG | Staging inside iCloud Drive baked `com.apple.fileprovider.fpfs#P` and `com.apple.FinderInfo` attributes into the image and `codesign` rejected the installed app. Fixed in `scripts/make-dmg.sh` by staging in `mktemp` outside iCloud, `ditto --noextattr`, `xattr -cr` and re-signing. |
| Not recorded | The overnight soak, the VPN test, the captive-portal test, the `/etc/hosts` blackhole test and a screenshot of the status item (Chrome fullscreen hid the menu bar). |

## Deviations from plan

### Changed during the build

Each of these was forced by something found while testing against an independent source, or by a user decision made after the plan was approved.

| Area | Plan said | Code does | Why |
|---|---|---|---|
| Download byte counting | A per-task `DownloadStreamDelegate` passed to `URLSession.data(for:delegate:)`. | `Sources/SpeedCore/SpeedTest/Cloudflare/DownloadStream.swift` owns its own `URLSession` and is that session's `URLSessionDataDelegate`. Bytes are counted in `urlSession(_:dataTask:didReceive:)`. | The async `data(for:delegate:)` API never calls `didReceive data` on a task-scoped delegate. The first live run reported a correct upload and a download of 0.0 Mbps. Only `UploadStreamDelegate` in `StreamDelegates.swift` remains task-scoped, because `didSendBodyData` does fire there. |
| Team ID | `DEVELOPMENT_TEAM: XB7X3VP977`. | `project.yml` sets `DEVELOPMENT_TEAM: Z6SX8L9HA7`. | `XB7X3VP977` is the suffix in the certificate's common name. The team ID is the certificate's OU, `Z6SX8L9HA7`. The plan and the research had confused the two. |
| Static library header phase | Not mentioned. | `project.yml` gives `SpeedCore` `SWIFT_INSTALL_OBJC_HEADER: NO` and an empty `SWIFT_OBJC_INTERFACE_HEADER_NAME`. `ENABLE_USER_SCRIPT_SANDBOXING` stays `YES`. | User script sandboxing blocked the static library's Objective-C header copy phase. The library has no Objective-C consumers, so the header is not generated. |
| Menu bar layout | Two right-aligned rows (down over up) in a 9 point font as the default, with one-line and dot-only alternatives. | `BarLayout` in `Sources/App/StatusBar/StatusItemView.swift` has four cases: `adaptive` (default), `twoLine`, `oneLine`, `dotOnly`. Adaptive draws one 11 point number with an arrow. The direction comes from `Sources/SpeedCore/Counters/ActiveDirectionSelector.swift`: download by default, upload only when upload exceeds 1.3 times download, with a 0.15 Mbps floor and a 3 second dwell. | User decision after seeing the two-line readout. The two-line layout is still selectable. |
| Launch at login | A toggle that registers only from `/Applications`. | `AppSettings.launchAtLoginWanted` defaults to `true`. `AppCoordinator.reconcileLaunchAtLogin()` runs on every launch from `/Applications` and re-registers or unregisters `SMAppService.mainApp` to match the preference. `AppDelegate` also accepts `--login-status`, `--register-login-item` and `--unregister-login-item` flags, which `scripts/uninstall.sh` uses. | User wanted it on by default. Registering once was not enough: after a reinstall the background task database records the replaced bundle and `status` reads `.notFound`, so the app silently stopped launching at login. Verified enabled across two reinstalls after the fix. |
| Bar number formatting | Not specified beyond fixed width. | `SpeedFormatter.bar` in `Sources/SpeedCore/Support/Formatters.swift` uses `roundingMode = .halfUp` and drops the decimal above 10 Gbps. | `NumberFormatter` defaults to banker's rounding, which turned 84.25 into "84.2". At or above 10 Gbps the string reached six characters and broke the fixed width. |
| DMG staging | Stage in `build/dmg`, `hdiutil -fs HFS+`. | `scripts/make-dmg.sh` stages in a `mktemp` directory outside iCloud Drive, copies with `ditto --noextattr --noqtn`, runs `xattr -cr`, re-signs with `--options runtime`, and builds with `-fs APFS`. The image itself is signed on a best-effort basis. | See the M11 row above. The DMG README file is named `READ ME FIRST.txt`. |
| Default isolation proof | Grep the build log for `-default-isolation=MainActor`. | Proved with a compile probe instead. | The flag never appears in the `xcodebuild` log. |

### Planned but not shipped, or only partly shipped

Each row was checked against the code before being written. "Setting only" means the preference exists in `Sources/App/AppSettings.swift` and is shown in `Sources/App/Settings/SettingsView.swift`, but nothing reads it.

| Feature | State in the code |
|---|---|
| Loaded-latency sampler | Not implemented. `SpeedTestResult` has `downloadLoadedLatencyMs` and `uploadLoadedLatencyMs`, but nothing writes them. There is no `LoadedLatencySampler` file and no 500 ms zero-byte request loop during throughput phases. |
| ISP and server fallback chain | Only the first step exists. `CloudflareSpeedTest.fetchMeta()` calls `/meta` with `Referer` and `Origin` under a 4 second deadline. On failure the result shows "Unknown ISP" and the server shows "Cloudflare". There is no `__down` header step, no Apple `mensura.cdn-apple.com` step, no `ISPResolver`, no `AppleISPLookup`, and no 10 minute cache. The server shown is the colo from `/meta`, not the colo that served the download. |
| Metered, constrained and Low Power confirmation sheet | Setting only (`confirmOnMetered`, default true). `SpeedTestController.start` checks only that no test is running, no rate-limit backoff is active and 30 seconds have passed. It does not read `PathSnapshot.isExpensive`, `isConstrained` or Low Power Mode, and it does not require a satisfied path or refuse to start on a captive portal. |
| Interface override picker | Not implemented. The Network tab shows the active interface, path status, expensive and constrained flags as read-only text, and says that speed tests follow the system default route. |
| Export | Not implemented. No export code exists. History lives in `Application Support/com.srimi.internetspeedreader/speedtests.json`, outages in `outages.json`, both written by `AtomicJSONStore`. |
| Liquid Glass background | Not implemented. No availability check for macOS 26 and no glass material anywhere in `Sources/App`. |
| One-line and dot-only layouts | Implemented in `StatusItemView.draw` and `StatusItemView.width(for:showUnits:unit:)`. Width is measured from `SpeedFormatter.widestBarSamples`. |
| Reopen the panel when a test finishes | Partly. The `reopenPanelOnFinish` setting exists (default true) and `StatusItemController.reopenPanelForResult()` exists, but nothing calls it. A test that finishes with the popover closed shows its result the next time the popover is opened. |
| Alert settings | Setting only. `notifyOnDrop`, `notifyOnRestore`, `notifyAfterSeconds` and `minimumOutageSeconds` are shown in the Alerts tab, but `AppCoordinator.startOutageEngine()` builds `OutageEngine` with the default `ConnectivityStateMachine.Config` (notify after 10 s) and `OutageLedger.makeDefault()` with the default 3 s minimum, and `AppCoordinator.handle(_:engine:)` posts both banners unconditionally. |
| Refresh policy | Setting only. `refreshPolicy` is shown in the General tab. Cadence comes from `PowerPolicy.currentCadence()` (1 s on AC, 2 s on battery, 5 s in Low Power Mode), evaluated once in `AppCoordinator.startLiveMeter()`. It is not re-evaluated when the power source changes. |
| Apple deep test runtime | Setting only. `appleMaxSeconds` is shown, but `SpeedTestController.startAppleDeepTest` calls `NetworkQualityRunner.run(interfaceName:)` with the default `maxSeconds: 15`. |
| Notification actions | The `OUTAGE` category with "Run Speed Test" and "Show Outage Log" actions is registered in `NotificationService`, but `onRunTestRequested` and `onShowLogRequested` are never assigned, so tapping an action only brings the app forward. |
| Rate-limit backoff | Single 15 minute block in `SpeedTestController.fail`. The 15 minute, 1 hour, 6 hour escalation is not implemented. |
| Byte-cap halving retry | `ResponseValidator.validateDownload` recognises a 403 with a one-byte body as `.byteCapExceeded`, but `runDownloadPhase` does not halve the chunk and retry. `ChunkLadder.maxBytes` is 50 MiB, so the cap is not reached in normal operation. |
| Path generation abort | `PathSnapshot.generation` and `SpeedTestError.networkChanged` exist, but the engine never compares generations and never throws `networkChanged`. |
| Whole-test derived deadline | Not implemented as one deadline. Phases have their own limits: meta 4 s, latency 6 s, download probe 5 s, session resource timeouts of phase length plus 5 s, and `NetworkQualityRunner` at `maxSeconds` plus 10 s. |
| Injected session factory and `StubURLProtocol` | Not implemented. `CloudflareSpeedTest.makeSessionConfiguration(timeoutSeconds:)` is a static function and the tests contain no `URLProtocol` stub. Consequently there is no two-stream aggregation phase test and no prober hang test; the sum-versus-average rule is covered by the `ByteLedger` test and the aggregator tests in `Tests/SpeedCoreTests/SpeedTestMathTests.swift`, and the prober deadline was measured live rather than unit tested. |
| Result details disclosure | Not implemented. The stored fields (`networkProtocol`, `downloadStreams`, `downloadMeanMbps`, `downloadPeakMbps`, `uploadVerifiedBytes`, `tcpMinRttMs`) are persisted but the panel shows only PING, JITTER, DOWNLOAD and UPLOAD, relabelled BASE RTT and RPM for Apple runs. |
| Monthly data projection | Not implemented. `AppCoordinator.dataEstimateText` gives a per-test estimate only. |
| Gauge ticks | Not drawn. `GaugeView` has the 270 degree arc, the logarithmic 0.1 to 1000 Mbps mapping and Reduce Motion handling, but no tick marks at 1, 10, 100 and 1000. |
| Outage Log menu item | Not in the right-click menu. Outages are shown in the panel's Outages tab. The menu instead carries the M1 spike item "Send Test Notification" and two disabled status lines (notification permission, whether the app runs from `/Applications`). |
| Settings tabs | Four tabs (General, Alerts, Speed Test, Network), not five. Pause Alerts lives in the right-click menu only. |

### Smaller differences

- File names differ from the plan in several places: there is no `NotificationSink.swift`, `SpeedTestHistory`, `PopoverController`, `StatusItemMenu`, `StreamPool`, `LatencyPhase` or `SpeedTestEngine` protocol. The outage engine emits an `AsyncStream<OutageEvent>` that `AppCoordinator` turns into notifications; the popover and the context menu live in `StatusItemController`; history is an `AtomicJSONStore<SpeedTestResult>` inside `SpeedTestController`; the download loop is inline in `CloudflareSpeedTest.runDownloadPhase`.
- `ThroughputSampler.swift` holds the pure `ThroughputCalculator`; the sampling actor is `LiveThroughputMonitor.swift`.
- The bar's smoothing is an exponential average with factor 0.5 in `AppCoordinator.ingest`, not a three-sample average.
- `ProcessInfo.beginActivity` is held for the whole process lifetime from `AppCoordinator.start()`, not only on AC, while the panel is open, or during a test.
- The latency phase treats only the first of the 20 samples as cold, rather than detecting connection reuse per sample.
- After the 3 second path debounce the state machine opens a `.pathUnsatisfied` outage directly rather than passing through `suspect`.
- `HTTPProber` gives the primary HEAD request a 1.5 second sub-budget inside the 3 second round, then spends the remainder on the captive-portal GET.
- `NetworkQualityRunner` drains both pipes in the termination handler rather than concurrently while the process runs.
- The popover is 330 points wide, not 320.
- The live meter's measured overhead was 9.6 percent, slightly below the 10 to 17 percent the plan quotes; the README and tooltip say "about 10 percent".

## Approved plan (2026-09-04)

The plan below is reproduced from `~/.claude/plans/okla-i-want-to-twinkly-nygaard.md` as approved before the build started. Headings are shifted down one level so the plan nests under this section; the text is otherwise unchanged. Where it disagrees with the code, the code wins and the section above records the difference.

## Internet Speed Reader — macOS menu bar speed + outage monitor

### Context
- You want an Ookla-style internet speed reader that lives in the top-right menu bar of your Mac, runs locally, and above all tells you the moment your internet drops and the moment it comes back. Today you find out by accident.
- Your attached image did not reach me. Working from your answers instead: menu bar top-right; bar shows live ↓/↑ throughput; engine is built-in zero-install; alerts are a notification banner plus a red menu bar plus an outage log.
- Work happens in `https://github.com/Srimi1/Internet-speed-reader.git` (Apache-2.0, currently LICENSE + README only). The local folder is empty and sits inside iCloud Drive, so step one is a clone into it.
- Host verified today: macOS 26.6.2 Tahoe, Apple Silicon, Xcode 26.6, Swift 6.3.3, SDK 26.5, XcodeGen 2.45.4 at `/opt/homebrew/bin/xcodegen`. `security find-identity -v -p codesigning` returns exactly one identity, `Apple Development: 917762034141 (XB7X3VP977)`, and no Developer ID. `swiftc -help-hidden` confirms `-default-isolation MainActor|nonisolated`.
- Cloudflare endpoints verified live today: `/meta` needs a `Referer` header or returns 403 `{}`; `__down?bytes=N` caps at 52428800 and 403s above it; `__up` ignores `bytes=` and needs a real body; the host negotiates HTTP/1.1 only. Measured 120 Mbps single stream, ~160 Mbps across four.
- This is version 1.0.0 of the app, and the last step ships a distributable `InternetSpeedReader-1.0.0.dmg`. `hdiutil` is present; `create-dmg` is not installed and is not needed.
- Deployment target macOS 14.0, App Sandbox off, no entitlements file, v1 has no scheduled tests, no global hotkey, no auto-updater, no notarization.

### Decisions (locked)
- Two targets: `SpeedCore` (static library, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`) holds all measurement and state logic; `InternetSpeedReader` (app, `MainActor`) holds AppKit and SwiftUI. The test bundle depends on `SpeedCore` only, with no TEST_HOST, so `xcodebuild test` never launches the agent app.
- AppKit `NSStatusItem` with a custom `NSView`, not SwiftUI `MenuBarExtra`. Verified against the SDK: the `MenuBarExtra` label is limited to `Text` or `Label<Text, Image>`, there is no way to dismiss its window programmatically, and it offers no right-click. macOS 26 adds nothing to it.
- Sign with the existing `Apple Development` identity, `CODE_SIGN_STYLE: Manual`, `DEVELOPMENT_TEAM: XB7X3VP977`, no provisioning profile. A team-anchored designated requirement survives rebuilds, so the notification grant and the login item registration persist. Ad-hoc `-` is the documented fallback with hardened runtime off.
- Cloudflare engine uses N independent `URLSession`s each with `httpMaximumConnectionsPerHost = 1`, so N streams are N TCP connections by construction and a future switch to HTTP/2 cannot silently collapse them.
- Request sizing is per-stream and never divided by N: `size = clamp(pow2Ceil(perStreamBytesPerSec * 2.0), 256 KiB, 50 MiB)`, re-derived every request.
- Upload bodies are file-backed via `uploadTask(with:fromFile:)` against pre-generated fixtures of 1, 4, 16 and 32 MiB in Caches. No custom `InputStream` subclass anywhere in v1.
- The menu bar shows link-layer throughput of one active interface from kernel `if_data64` counters, which runs about 10 to 17 percent above payload and covers all apps. The speed test shows app-layer payload Mbps. Both are labelled and never mixed.
- Outage hysteresis: two consecutive probe failures mean down, one success means up. An unsatisfied network path means down after a 3 second debounce. A captive portal is its own state. A banner fires only after 10 seconds of confirmed outage and only outside a grace window.
- Grace windows are 20 seconds after wake, 15 seconds after an interface switch, 10 seconds after launch. Grace gates banners only; the outage log records honestly throughout.
- All time comes from an injected `TimeSource`, and every network call is wrapped in a `withDeadline` task-group race, because `URLSession` and `NWConnection` can stay silent forever on a blackholed route.
- Live meter cadence is 1 second on AC, 2 seconds on battery, 5 seconds in Low Power Mode. Correctness never depends on cadence because every rate divides by measured `ContinuousClock` elapsed time.

### Architecture and file layout
```
project.yml  .gitignore  README.md  LICENSE
scripts/install.sh  scripts/uninstall.sh
Support/Info.plist                  # outside every sources root, never copied as a resource
Sources/SpeedCore/…  Sources/App/…  Tests/SpeedCoreTests/…
```
- `Sources/SpeedCore/Support/`: `TimeSource.swift`, `Deadline.swift` (`withDeadline`), `AtomicJSONStore.swift` (versioned envelope, atomic write, renames to `.bak` on unknown version), `AppPaths.swift`, `Log.swift` (`os.Logger`, subsystem `com.srimi.internetspeedreader`), `RingBuffer.swift`, `Formatters.swift`.
- `Sources/SpeedCore/Counters/`: `InterfaceCounters.swift`, `RouteMessageParser.swift` (pure walk over a raw buffer), `SysctlCounterReader.swift`, `ThroughputSampler.swift` (actor emitting an `AsyncStream`).
- `Sources/SpeedCore/Path/`: `PathSnapshot.swift` with a pure `ActiveInterfaceSelector`, `NWPathSource.swift`.
- `Sources/SpeedCore/Probe/`: `ConnectivityProbe.swift` with `Prober`, `HTTPProber` and `ProbeOutcome`.
- `Sources/SpeedCore/Outage/`: `ConnectivityStateMachine.swift` (pure struct reducer), `OutageEngine.swift` (actor owning probes, timers and graces), `OutageLedger.swift`, `NotificationSink.swift`.
- `Sources/SpeedCore/SpeedTest/`: `SpeedTestEngine`, `SpeedTestResult`, `SpeedTestHistory`, and under `Cloudflare/`: `CloudflareEndpoints`, `CloudflareMeta`, `ServerTiming`, `ByteLedger` (`OSAllocatedUnfairLock`), `ChunkLadder`, `StreamPool`, `DownloadStreamDelegate`, `UploadStreamDelegate`, `SliceSampler`, `ThroughputAggregator`, `LatencyPhase`, `LoadedLatencySampler`, `UploadFixture`, `ResponseValidator`, `CloudflareSpeedTest` (actor), `ISPResolver`.
- `Sources/SpeedCore/Apple/`: `NetworkQualityRunner` (actor wrapping `Process`), `NetworkQualityReport` (all-optional `Decodable`), `AppleISPLookup`.
- `Sources/App/`: `InternetSpeedReaderApp.swift` (the only SwiftUI scene is `Settings`), `AppDelegate.swift`, `AppCoordinator.swift` (composition root, mirrors async streams into UI state), `PowerPolicy.swift`, `NotificationService.swift`, `LoginItemManager.swift`, `AppSettings.swift`.
- `Sources/App/StatusBar/`: `StatusItemController`, `StatusItemView`, `StatusItemMenu`. `Sources/App/Popover/`: `PopoverController`, `PanelView`, `GaugeView` with `GaugeArc`, `ResultTilesView`, `LiveSectionView` with `SparklineView`, `HistoryTabView`, `OutageTabView`. `Sources/App/Settings/`: `SettingsView` plus five tab views.
- Isolation convention: everything in `SpeedCore` is nonisolated, everything in the app target is main-actor. Crossing happens only through `await` on `SpeedCore` async APIs and stream consumption in `AppCoordinator`.

### Speed test engine (Cloudflare)
- The session factory is injected as `@Sendable (StreamRole) -> URLSessionConfiguration` so `StubURLProtocol` works in tests. Config: ephemeral, `waitsForConnectivity = false`, no cache, `httpMaximumConnectionsPerHost = 1`, no pipelining, request timeout 10, resource timeout phase budget plus 5, `Accept-Encoding: identity`, and an honest user agent naming the repo.
- Preflight requires a satisfied path. On an expensive, constrained or Low Power link it shows a confirmation sheet with a data estimate. It suspends the outage engine, holds `ProcessInfo.beginActivity`, and captures the path generation.
- The whole-test deadline is derived, not hardcoded: 6 for latency, 3 for the download probe, D plus 4, 3 for the upload probe, U plus 4, and 8 spare. That is 39 seconds at the defaults of D=10 and U=8.
- Meta phase, 4 second deadline: `GET /meta` with `Referer` and `Origin`. `CloudflareMeta` uses a hand-written initializer because `asn` may be a number or string, `colo` an object or string, and latitude and longitude strings or doubles. Any failure returns nil rather than throwing. Cached 10 minutes per interface and path generation.
- Latency phase, capped at 6 seconds: 20 sequential `GET /__down?bytes=0` on a dedicated session. Each sample is `(responseStart − requestStart) × 1000` minus `cfSpeedEdge + cfSpeedWorker`, clamped at zero. Cold samples where the connection was not reused are discarded unless fewer than five warm ones remain. Ping is the median, jitter the mean absolute difference between consecutive samples.
- The `cfL4` header also yields a server-measured `min_rtt`, stored separately and labelled "TCP RTT (server-measured)". Packet loss is nil and rendered as a dash; the `lost` and `retrans` counters are never presented as packet loss because they read zero on healthy and mildly lossy links alike.
- Download phase, 10 second budget by default with a hard cap of budget plus 4 and a 1.5 GiB byte ceiling: a 1 MiB ramp probe, then six streams each looping `GET /__down?bytes=B` with B from `ChunkLadder` until the deadline, at which point every session is invalidated.
- Response validation is a hard abort, never a number: status 200, `Content-Type` starting with `application/octet-stream`, and `expectedContentLength` equal to B. Anything else is an interception error. A 403 with `Content-Length: 1` is treated as the byte cap, so B halves once and retries.
- Bytes accumulate in one shared `ByteLedger` across all streams, so requests cancelled at the deadline lose nothing.
- Aggregation: a slice sampler ticks every 100 ms and computes `Δbytes × 8 / 1e6 / measuredΔt`, never the nominal interval. Slices before 1.5 seconds are discarded as warm-up, the rest sorted, the lowest 30 percent and highest 10 percent dropped, and the headline is the mean of the remainder.
- Alongside the headline the result stores the byte-weighted mean, the p95 peak, total bytes, seconds, stream count and chunk size, so the aggregation choice is auditable and switchable by one constant. Fewer than 10 post-warm-up slices means insufficient data.
- Server processing time is subtracted from latency only, never from throughput, because throughput measures bytes against a wall clock rather than per-request duration. That sentence goes in a code comment so nobody "fixes" it later.
- Upload phase, 8 second budget and 1 GiB ceiling: four streams each looping `POST /__up` with an explicit `Content-Length` from the fixture rung nearest two seconds of per-stream throughput. Bytes come from `didSendBodyData` deltas, and each completed request verifies that `cf-meta-upload-bytes` matches the file size.
- Loaded latency runs on its own session, one zero-byte request every 500 ms during both throughput phases, medians stored per direction for Ookla parity.
- The ISP and server chain, each step with a 3 second deadline and a 10 minute cache: `/meta` first, then `__down` response headers, then Apple's `https://mensura.cdn-apple.com/.well-known/nq` headers, then "Unknown ISP". It is never blank, and the server shown is the colo that actually served the measurement.
- Cancellation cancels the run task, checks `Task.isCancelled` in every loop, and invalidates every session through a cancellation handler. A cancelled result is never persisted, GO becomes STOP during a run, a path generation change aborts as a network change, and tests are spaced at least 30 seconds apart.
- A 403 or 429 produces a rate-limited state, copy pointing at the Apple deep test, and a 15 minute, 1 hour, 6 hour backoff.

### Apple deep test (networkQuality)
- `NetworkQualityRunner` is an actor spawning `/usr/bin/networkQuality` with `-c -s -M 15`. The camelCase path is hardcoded because that is the real binary name, and `-M` is a soft cap that runs 2 to 4 seconds over.
- Both stdout and stderr drain concurrently off the main actor, completion arrives through the termination handler, and a hard deadline of M plus 10 terminates the process, escalating to a kill after 2 seconds.
- Every field in `NetworkQualityReport` is optional because the JSON schema differs between default and sequential mode. Throughput keys are bits per second. Dates parse with a fixed format in the local time zone.
- Apple numbers live in their own `AppleExtras` and their own card labelled `Apple CDN` with the endpoint. The Apple base round-trip time is never written into the ping field and is never called idle latency.

### Live throughput monitor
- `SysctlCounterReader` uses `NET_RT_IFLIST2`, walks messages with `loadUnaligned`, always advances by `ifm_msglen`, and reads the 64-bit `if_data64` counters. The 32-bit `getifaddrs` counter is verified to have already wrapped on this machine and is never used for bytes.
- The walk lives in a pure `RouteMessageParser` so it is testable against synthetic buffers.
- `ActiveInterfaceSelector` dedupes the available interfaces by index, since en0 is verified to appear twice, prefers the first Wi-Fi or wired interface, and otherwise takes a tunnel. Interfaces are never summed.
- VPN rule: when only a tunnel is available the meter counts the tunnel and the popover chip says so, and when a physical interface exists it wins. A real VPN gets exercised in M3 rather than assumed.
- The sampler requires at least 0.2 seconds between reads, uses wrapping deltas, and rebaselines instead of emitting when a counter decreases, when the gap exceeds 5 seconds, or when the derived rate exceeds 50 Gbps.
- Rebaseline triggers are first tick, wake, interface change, path recovery, resume, and a refresh-interval change. The sampler pauses on sleep so no post-wake giant delta can exist.
- Power: `ProcessInfo.beginActivity` is the primary App Nap defense, held on AC and whenever the panel is open or a test runs. `LSAppNapIsDisabled` in Info.plist is belt-and-braces, since the documented `NSAppSleepDisabled` is a user default rather than an Info.plist key.
- The displayed value is a three-sample exponential average, and a 120-sample ring buffer feeds the sparkline. Byte counters are never used as an internet-is-up signal, because LAN traffic flows during WAN outages.

### Outage engine and notifications
- `ConnectivityStateMachine` is a pure struct with no clocks or I/O. States are unknown, online, suspect, down, captive portal and suspended. Events are path, probe, tick, sleep, wake, manual check and speed-test start or finish. Effects are scheduling, bar updates, ledger open and close, and notify down or up.
- Online plus a failure becomes suspect and probes again in 2 seconds. Suspect plus a failure becomes down with the start stamped at the first failure, which keeps the duration honest. Suspect plus a success returns to online with no ledger entry.
- An unsatisfied path becomes suspect after a 3 second debounce, which kills the red flash on every access-point roam. A satisfied path never declares online by itself; it schedules an immediate probe, because a captive portal satisfies the path.
- A captive portal is its own state: red bar, a header reading "Captive portal detected, sign in", its own ledger reason, and the speed test refuses to start.
- Sleep suspends the machine state and closes any open outage, so there is no dangling all-night record and no restore banner it cannot time honestly. While suspended every path, probe and tick event is ignored, which is what makes Power Nap dark wakes safe.
- `HTTPProber` uses one long-lived ephemeral session. A round is a HEAD to `https://www.gstatic.com/generate_204` expecting exactly 204, then on failure a GET to `http://captive.apple.com/hotspot-detect.html` whose body must contain "Success". The whole round shares one 3 second deadline so the 2 second failure cadence stays reachable on a blackholed route. Offline is declared only when both fail. There is no ICMP and no gateway probing, which would trip the Local Network prompt.
- Cadence is 15 seconds online, 2 seconds while suspect or down, and 30 seconds after ten consecutive failures, with immediate probes on path change, wake, panel open and manual check.
- `NotificationService` requests alert authorization only, never sound, badge or critical alert. The delegate is set before launch returns. The category carries "Run Speed Test" and "Show Log" actions. The restore notification removes the delivered drop notification first so the pair collapses.
- The interruption level is active, because time-sensitive needs an Apple-granted entitlement. Settings says plainly that Focus modes can hide the banner and that the red menu bar is the guaranteed signal.
- `OutageRecord` is Codable with a schema version, start, confirmation time, end, interface, cause, unsatisfied reason, failure kinds, whether it was notified, and how it ended. Storage is an atomic JSON file under Application Support, capped at 500 records, dropping anything shorter than 3 seconds.
- A `lastAlive` heartbeat writes to user defaults every 60 seconds so that a crash or force quit never leaves an eternal ongoing outage; at launch any open record closes at the heartbeat time.

### Menu bar item and popover UI
- The status item uses a fixed width and an autosave name. Placement next to the clock cannot be programmed, so the README documents Command-drag and the autosave name makes the choice stick.
- Fixed width is measured from the widest strings the layout can ever draw and recomputed on settings or appearance changes, so the right side of the menu bar never shuffles.
- `StatusItemView` is a subview of the status button, drawing two right-aligned rows in a 9 point monospaced-digit font, never `attributedTitle`, which is known to clip.
- Colors are semantic: label color for text, green online, orange while suspect or in grace, red offline or captive portal, blue while testing. The red state colors the dot and both rows.
- Three layouts exist: two-line, one-line, and dot-only, the last being the only workable option on a notched MacBook where a wide item is silently hidden by overflow.
- Left click toggles the popover with button highlighting; right or control click assigns the context menu, clicks it, and clears it in `menuDidClose`.
- The popover is transient, 320 points wide, hosting SwiftUI. Opening fires an immediate probe. A running test continues when the popover closes, the dot stays blue, and the panel reopens automatically on completion, with a setting to disable that. A non-activating floating panel is the documented follow-up.
- Panel sections: status header with interface chip and gear menu, live tiles with a sparkline, the gauge, result tiles, the ISP and server row, History and Outages tabs, and a footnote explaining the live versus test difference.
- The gauge is an animatable `Shape` with a 270 degree sweep and a logarithmic mapping from 0.1 to 1000 Mbps, with ticks at 1, 10, 100 and 1000, easing disabled under Reduce Motion. The GO button sits inside the gauge centre and becomes STOP during a run.
- Result tiles are PING, JITTER, DOWNLOAD and UPLOAD, relabelled for Apple runs, with a details disclosure showing protocol, streams, loaded latency, TCP round-trip, mean and peak, server-confirmed upload bytes and data used.
- The right-click menu offers Run Speed Test, Apple Deep Test, Check Connection Now, Pause Alerts for an hour or until tomorrow, Outage Log, Launch at Login, Settings, About and Quit. Pausing keeps the red bar and the ledger working.

### Settings, login item, persistence
- General: launch at login, bar layout, show units, Mbps or MB/s, and refresh policy.
- Alerts: notify on drop and restore, notify-after delay defaulting to 10 seconds, minimum logged outage of 3 seconds, pause alerts, authorization status with a button to open the right settings pane, and the Focus-mode footnote.
- Speed Test: download streams defaulting to six, upload streams defaulting to four, phase duration, per-test data cap, confirmation on metered links, data-saver mode, Apple deep test runtime, and a data estimate.
- Network: interface override with the note that `URLSession` cannot bind to an interface, so the override affects the live meter and the Apple test only, plus read-only diagnostics.
- `LoginItemManager` wraps `SMAppService.mainApp`, maps requires-approval to a button that opens Login Items settings, treats already-registered as success, and registers only from `/Applications` because the background task database records the path.
- Persistence uses a versioned atomic JSON store: 200 speed test results, 500 outages, both under Application Support, with upload fixtures in Caches. The bundle identifier `com.srimi.internetspeedreader` never changes, because notifications, login items and defaults all key off it.

### Build, sign, install
- `project.yml` declares `SpeedCore` as a static library with nonisolated default isolation, the app with main-actor default isolation, and the test bundle depending on `SpeedCore` only so there is no test host. Info.plist lives outside every sources root.
- Base settings: Swift 6 language mode, deployment target 14.0, marketing version 1.0.0, manual signing with the Apple Development identity and team XB7X3VP977, hardened runtime on, no entitlements block at all.
- Info.plist carries `LSUIElement`, `LSAppNapIsDisabled`, the minimum system version, the utilities category, and an App Transport Security exception for `captive.apple.com`, without which the plain-HTTP captive probe fails every time.
```bash
set -euo pipefail; REPO="/Users/srimi/Library/Mobile Documents/com~apple~CloudDocs/internet-speed-reader"; DD="$HOME/Library/Developer/Xcode/DerivedData/InternetSpeedReader"; cd "$REPO" && /opt/homebrew/bin/xcodegen generate --spec project.yml && xcodebuild -project InternetSpeedReader.xcodeproj -scheme InternetSpeedReader -configuration Release -derivedDataPath "$DD" build && osascript -e 'tell application "InternetSpeedReader" to quit' 2>/dev/null; rm -rf /Applications/InternetSpeedReader.app && ditto "$DD/Build/Products/Release/InternetSpeedReader.app" /Applications/InternetSpeedReader.app && codesign --verify --strict /Applications/InternetSpeedReader.app && open /Applications/InternetSpeedReader.app
```
- DerivedData stays outside iCloud Drive. The generated Xcode project is git-ignored and regenerated. Paths are quoted everywhere because the repo path contains spaces.
- M0 must confirm the build log actually contains `-default-isolation=MainActor`, since Xcode silently ignores unknown build settings.
- Never run through `swift run`: `UNUserNotificationCenter` throws without a real bundle.
- The ad-hoc fallback overrides the identity to `-`, clears the team and turns hardened runtime off, at the cost of re-granting notifications after each rebuild.

### DMG packaging
- `scripts/make-dmg.sh` builds the Release app, stages it with a symlink to `/Applications`, and produces `dist/InternetSpeedReader-1.0.0.dmg`. It runs after the app is verified, not before.
- Staging: copy the built app with `ditto` into a clean `build/dmg` folder, add `ln -s /Applications "build/dmg/Applications"` so the drag-to-install layout works, and include a short `README.txt` covering the first-launch Gatekeeper step.
- Image: `hdiutil create -volname "Internet Speed Reader" -srcfolder build/dmg -ov -format UDZO -fs HFS+ dist/InternetSpeedReader-1.0.0.dmg`, then `hdiutil verify` it and print the SHA-256 for the release notes.
- Optional window layout: build a read-write UDRW image first, mount it, position the icons and set the background with `osascript` against Finder, detach, then `hdiutil convert -format UDZO`. This is cosmetic and can be skipped if it proves flaky.
- Sign the disk image itself with the same identity so its contents are not tampered with in transit: `codesign --sign "Apple Development: 917762034141 (XB7X3VP977)" dist/InternetSpeedReader-1.0.0.dmg`.
- Honest limitation: this build is signed for development and is not notarized, so on any other Mac Gatekeeper will refuse the first launch. The DMG README and the GitHub release notes must state the workaround, which is opening the app from the right-click menu once, or running `xattr -dr com.apple.quarantine /Applications/InternetSpeedReader.app`. Removing that friction needs a paid Developer ID certificate and notarization, which is out of scope for v1.
- The `dist/` folder is git-ignored; the DMG is attached to a GitHub release rather than committed.

### Milestones (ordered)
1. **M0 bootstrap and toolchain proof.** Clone, add `project.yml`, `.gitignore`, scripts, empty targets and one trivial test. Verify the Release build succeeds, the isolation flag appears in the log, tests run without launching the app, and there is no Dock icon.
2. **M1 signing and permissions spike.** Add only a "Send test notification" item and a launch-at-login toggle. Rebuild and reinstall three times and confirm both grants survive. Record the outcome in the README.
3. **M2 counters and sampler.** Verify against `netstat -I en0 -b -w 1` during a 50 MiB download, within about 5 percent, and that synthetic-buffer parser tests pass.
4. **M3 path and menu bar item.** Verify no width jitter from 0.0 to 9999, correct rebaseline on Wi-Fi off and on, dock and undock, and a real VPN connect and disconnect, plus legibility on light and dark wallpapers.
5. **M4 outage engine.** Verify Wi-Fi off turns the bar red within about 4 seconds with an honest start time, a blackhole via `/etc/hosts` is detected, and sub-3-second blips leave no record.
6. **M5 notifications and sleep or wake.** Verify from `/Applications` that the drop banner arrives at about 10 seconds, the restore banner replaces it, and lid close and network switching produce zero banners.
7. **M6 popover and settings.** Verify transient dismissal, that activity is held while open, and that Low Power Mode drops cadence to 5 seconds in the logs.
8. **M7 Cloudflare latency and ISP.** Verify ping lands within a few milliseconds of `ping -c 5 speed.cloudflare.com` and of the server-measured value, and that the ISP chain still names an ISP when `/meta` 403s.
9. **M8 Cloudflare throughput.** Verify results land within 10 to 15 percent of speedtest.net on the same link, that `lsof` shows the expected connection count, that memory stays flat during upload, and that STOP is instant.
10. **M9 history, guardrails and Apple deep test.** Verify history survives relaunch, the Apple run finishes in about 18 seconds, and cancelling leaves no `networkQuality` process behind.
11. **M10 polish.** Accessibility, Reduce Motion, locale formatting, Liquid Glass under an availability check, an overnight soak, the README, and the uninstall script.
12. **M11 DMG and release.** Add `scripts/make-dmg.sh`, produce and verify `dist/InternetSpeedReader-1.0.0.dmg`, mount it and install from it onto this Mac as a clean-install rehearsal, tag `v1.0.0`, and publish a GitHub release with the DMG, its SHA-256 and the Gatekeeper note attached.

Each milestone is a commit on a feature branch; the branch opens a pull request against `main` when M4 lands and merges when M11 is verified.

### Tests
- Swift Testing in `SpeedCoreTests`, no network and no test host. Fakes cover the clock, counters, path, prober, notification sink, store, and a `StubURLProtocol` injected through the session factory.
- The stub serves download bytes at a configurable pace with correct headers, echoes upload byte counts, 403s `/meta` without a referer, and offers portal-HTML, byte-cap and hang-forever modes.
- Parser tests use synthetic route-message buffers including a counter above 2^32, an odd message length proving offset advancement, and a truncated trailing message.
- Sampler tests cover a 1.05 second interval producing no over-report, counter decreases forcing a rebaseline, long gaps discarded, and a sanity ceiling.
- Aggregator tests cover the warm-up boundary, the trim arithmetic, byte-weighted mean and peak, and insufficient-data handling.
- One phase test is the direct regression for summing rather than averaging per request: a stub serving a fixed per-stream pace with two streams must aggregate to roughly twice that pace.
- Validator tests confirm that portal HTML and a content-length mismatch abort with no number, and that a 403 with a one-byte body triggers exactly one halving retry.
- Decoding tests cover Cloudflare's polymorphic fields and both `networkQuality` schemas including local date parsing.
- State machine tests, driven by a fake clock, cover every transition: honest start stamps, the debounce, grace windows gating banners but not records, restore only when a drop was notified, cadence escalation, suspended-state event dropping, and sleep closing the open record.
- Prober tests confirm the hang case resolves at about 3 seconds, proving the round-level deadline.

### Verification checklist (end to end)
1. The bar holds constant width from 0.0 to 9999, Command-drag reorders it and the position persists after relaunch, and dot-only works when the bar is crowded.
2. Live numbers track `netstat` within about 5 percent during a large download and read near zero when idle.
3. Wi-Fi, sleep, dock and VPN transitions produce no spikes or negatives, and the header names the right interface.
4. Three speed tests against speedtest.net and speed.cloudflare.com in the same minute land within 10 to 15 percent, with plausible ping and jitter, expected connection counts, flat memory and an instant STOP.
5. Redirecting `speed.cloudflare.com` to a local HTML server makes the test fail as an interception and record no number.
6. Blocking both probe hosts turns the bar red within about 4 seconds with an honest start, the drop banner arrives at about 10 seconds, and restore is green within 15 seconds with a duration in the banner.
7. A two minute lid close and an overnight sleep produce zero banners, no fake all-night record, and no post-wake spike. Switching Wi-Fi networks produces zero banners.
8. A captive portal shows the sign-in header, a red bar and a disabled GO, and clears after login.
9. Force-quitting during an outage and relaunching closes the record at the heartbeat rather than leaving it ongoing.
10. The Apple deep test finishes in about 18 seconds in its own labelled card and never writes into the Cloudflare ping column.
11. Launch at login appears in System Settings and survives a log out and back in; Pause Alerts suppresses banners while the bar still goes red.
12. Rebuilding and reinstalling twice preserves both the notification grant and the login item.
13. VoiceOver reads the bar value and the gauge, Reduce Motion disables easing, and the bar stays readable on light and dark wallpapers.
14. An overnight soak shows flat memory, near-zero CPU, probes at the expected cadence and no probes during sleep.
15. The uninstall script leaves no app, support files, caches, defaults or login item.
16. The DMG mounts as "Internet Speed Reader" with the app and an Applications shortcut side by side, `hdiutil verify` passes, `codesign --verify` passes on both the image and the app inside it, the app installed by dragging from the DMG launches and shows version 1.0.0 in About, and the file size is reasonable for a single-binary app.

### Risks and mitigations
- **Signing and permission churn.** The Apple Development identity gives a stable designated requirement, and M1 proves it before anything depends on it. That certificate expires in about a year, at which point the fallback is renewal or ad-hoc with re-granted notifications.
- **Cloudflare is not a documented third-party API.** The referer gate, the 50 MiB cap and the bot rules can change silently. Mitigations are defensive decoding, the ISP fallback chain, chunk halving, an honest user agent, on-demand tests only with 30 second spacing, backoff on 403 and 429, and the Apple engine as an alternative.
- **A future move to HTTP/2** is neutralised by one session per stream, and the negotiated protocol is logged so the change is visible rather than silent.
- **Upload optimism**, since `didSendBodyData` counts bytes handed to the socket, is mitigated by the warm-up discard, the trimmed mean and server-confirmed byte totals, and must be checked against speedtest.net on a slow uplink.
- **App Nap** is handled by `beginActivity` first and the Info.plist key second, and even if both fail, dividing by measured elapsed time means throttling degrades cadence rather than correctness.
- **VPN path behaviour is untested**, so the selector handles both shapes, the displayed quantity is stated in the UI, and M3 exercises a real tunnel.
- **Focus modes hide active-level banners**, so the red menu bar is the guaranteed signal and Settings says so.
- **Menu bar overflow** on notched Macs can hide a wide item with no API to prevent it, which the one-line and dot-only layouts address.
- **Live and test numbers differ by 10 to 17 percent** by construction, which labels, a tooltip and a README section explain rather than hide.
- **The transient popover dismisses mid-test**, so the run continues and the panel reopens on completion, with a floating panel as the documented upgrade.
- **`networkQuality` is undocumented**, so every field is optional, both pipes drain off the main actor, and there is a hard kill timeout.
- **iCloud Drive hosting the repo** risks sync conflicts, so DerivedData and caches stay outside, the project file is regenerated rather than committed, and moving the checkout out of iCloud is the escape hatch.
- **Per-test data usage** reaches about 1.5 GB on a gigabit link, mitigated by the metered confirmation, data-saver mode, byte ceilings and a monthly projection.
- **The DMG is not notarized**, so other Macs block the first launch until the user opens it from the right-click menu or strips the quarantine attribute. The DMG README and release notes say this up front; a Developer ID certificate would remove the friction later.
