# Verification

This document records what was actually checked before Internet Speed Reader 1.0.0 was released, and gives the procedure for checking a change afterwards.

Ground truth, in order: the code under `Sources/`, `Tests/`, `project.yml` and `scripts/`; the measurements taken during the 1.0.0 build session on 2026-09-04; the approved plan. Where the plan and the code disagree, the code wins and the disagreement is listed in "Deviations from the plan" below.

Every number in Part 1 was measured on one machine on one day. Treat them as evidence that the design works, not as guaranteed values. Part 2 tells you how to reproduce each check.

## Build host for 1.0.0

| Item | Value |
|---|---|
| Date | 2026-09-04 |
| macOS | 26.6.2 (Tahoe), Apple Silicon |
| Xcode | 26.6 |
| Swift | 6.3.3 |
| SDK | 26.5 |
| XcodeGen | 2.45.4 |
| Signing identity | `Apple Development: 917762034141 (XB7X3VP977)` |
| Team ID (certificate OU) | `Z6SX8L9HA7` |
| DerivedData | `~/Library/Developer/Xcode/DerivedData/InternetSpeedReader`, outside iCloud Drive |
| Repository | inside iCloud Drive; the path contains spaces |
| Network | Bharti Airtel Limited, client in Patna, nearest Cloudflare colo Kolkata (CCU) |

## Part 1: What was verified for 1.0.0

### Checks performed

Each row names the independent oracle the check was measured against. That matters: every bug in the next section was caught by comparing the app against something that was not the app.

| Check | How it was measured | Result | Code it exercises |
|---|---|---|---|
| Live meter counts the right bytes | A real 50 MiB download from `speed.cloudflare.com/__down` while reading en0 interface counters; interface bytes compared with the payload bytes curl reported | 57,447,424 interface bytes for 52,428,800 payload bytes in 2.976 s: 154.45 Mbps link-layer against 140.96 Mbps payload, 9.6 percent overhead | `Sources/SpeedCore/Counters/SysctlCounterReader.swift`, `Sources/SpeedCore/Counters/RouteMessageParser.swift`, `Sources/SpeedCore/Counters/ThroughputSampler.swift` |
| Live meter actor produces sane samples | A harness drove the real `LiveThroughputMonitor` during a transfer and while idle | 88 to 148 Mbps during the transfer, 0.01 Mbps idle | `Sources/SpeedCore/Counters/LiveThroughputMonitor.swift` |
| NWPath interface list shape | `NWPathMonitor.availableInterfaces` inspected on the host | en0 appears twice, once per address family; the selector dedupes by index | `Sources/SpeedCore/Path/PathSnapshot.swift` (`ActiveInterfaceSelector`), test `ActiveInterfaceSelectorTests.dedupes` |
| Cloudflare speed test end to end | One live run of the shipped engine at default settings | Download 176.3 Mbps (byte-weighted mean 158.7, p95 peak 292.1, 6 streams, 2048 KiB chunks, 205.5 MB moved); upload 137.9 Mbps (4 streams, 122.7 MB, every request server-confirmed through `cf-meta-upload-bytes`); ping 82.8 ms; jitter 15.6 ms; cfL4 TCP min RTT 32.1 ms; ISP "Bharti Airtel Limited"; client Patna; colo Kolkata (CCU); protocol `http/1.1`; wall time 23.6 s | `Sources/SpeedCore/SpeedTest/Cloudflare/CloudflareSpeedTest.swift` and the rest of `Sources/SpeedCore/SpeedTest/Cloudflare/` |
| Upload bytes are real | `cf-meta-upload-bytes` header on every upload response compared with the fixture size sent | All 122.7 MB confirmed by the server | `Sources/SpeedCore/SpeedTest/Cloudflare/ResponseValidator.swift` (`validateUpload`) |
| Latency method | 20 samples each of five methods against the same host in one sitting | See the latency table below | `measureLatency` in `CloudflareSpeedTest.swift`, `Sources/SpeedCore/SpeedTest/Cloudflare/ServerTiming.swift` |
| Prober on a healthy link | `HTTPProber.probe()` run from a harness | 216 ms on the cold first round, then 46 to 49 ms warm | `Sources/SpeedCore/Probe/ConnectivityProbe.swift` |
| Prober on a blackholed route | Endpoints pointed at 192.0.2.1 (TEST-NET, never answers) | Fails through the deadline at 3003 to 3006 ms against a 3000 ms round budget; the probe never hangs | `ConnectivityProbe.swift`, `Sources/SpeedCore/Support/Deadline.swift` |
| speed.cloudflare.com protocol | ALPN inspected live | The host negotiates HTTP/1.1 only. One 25 MiB stream reached 120 Mbps; four parallel streams summed to about 160 Mbps | Justifies one `URLSession` per stream and summing into one `ByteLedger` |
| Default actor isolation reaches the compiler | A probe file calling a `@MainActor` function synchronously was compiled in both targets | Compiles in the app target; fails in `SpeedCore` with "call to main actor-isolated global function in a synchronous nonisolated context". `SWIFT_DEFAULT_ACTOR_ISOLATION` never appears in the xcodebuild log, so this is the only proof | `project.yml` (`SWIFT_DEFAULT_ACTOR_ISOLATION` per target) |
| Unit tests | `xcodebuild test` | 75 tests in 16 suites pass, no network, no `TEST_HOST` (the test bundle depends only on `SpeedCore`, so the agent never launches) | `Tests/SpeedCoreTests/` |
| Signature of the installed app | `codesign --verify --strict` on `/Applications/InternetSpeedReader.app` | Passes after the DMG staging fix (bug 2 below) | `scripts/install.sh`, `scripts/make-dmg.sh` |
| DMG install round trip | `scripts/make-dmg.sh`, mount, drag to `/Applications`, verify, launch | App launches from the dragged copy and the signature verifies | `scripts/make-dmg.sh` |
| Login item survives reinstall | `scripts/install.sh` run twice after the reconcile fix (bug 6 below), status read with `--login-status` | `enabled` after both reinstalls | `Sources/App/AppCoordinator.swift` (`reconcileLaunchAtLogin`), `Sources/App/LoginItemManager.swift` |
| Notification permission prompt | Launch the installed build | The system prompt appeared, which proves the bundle and signature are acceptable to `UNUserNotificationCenter`. Allow had not been clicked at the time of writing | `Sources/App/NotificationService.swift` |
| Release artefacts | GitHub | PR #1 merged into `main` as commit `d0ee6db`; tag `v1.0.0`; release asset `InternetSpeedReader-1.0.0.dmg`, 1.5 MB (1,564,806 bytes), SHA-256 `4b11408d3d5d5c8e9d99d45311e8f3eb874048346fe0228d3e9609e353282f46` | `scripts/make-dmg.sh` |

### Latency study

Twenty samples per method, same host, same sitting. Values are medians in milliseconds.

| Method | Median |
|---|---|
| Raw HTTP round trip to `__down?bytes=0` | 77.2 |
| The same, minus `Server-Timing` (`cfSpeedEdge` + `cfSpeedWorker`) | 52.4 |
| Server-measured TCP `min_rtt` from the `cfL4` header | 46.1 |
| curl TCP connect time | 34 |
| ICMP ping | 20 |

Conclusion: HTTP minus server time tracks the server's own TCP RTT within about 6 ms, and it is the method speed.cloudflare.com itself uses. ICMP reads lower because it takes a different anycast path. The app therefore reports HTTP-minus-server-time as ping and stores `cfL4 min_rtt` separately as `tcpMinRttMs`. Server time is subtracted from latency only, never from throughput.

### What 1.0.0 is

The release branch carried these commits in order: M0 bootstrap; M1 to M3 permissions, counters, path, readout; M4 to M5 outage engine and notifications; M7 to M8 Cloudflare engine; M6 and M9 panel, settings and Apple deep test; M10 to M11 DMG and README; adaptive number plus login-at-launch default; login re-register fix.

Product decisions locked for 1.0.0: menu bar item top-right (user places it by Command-drag); a single adaptive number by default, download normally and upload only while uploading (ratio 1.3, floor 0.15 Mbps, dwell 3 s, in `Sources/SpeedCore/Counters/ActiveDirectionSelector.swift`); built-in Cloudflare engine with Apple `networkQuality` as an optional deep test; alerts are a banner plus a red bar plus the outage log, with no sound; launch at login on by default; a DMG; no scheduled tests, hotkey, auto-update or notarisation.

### Bugs found during verification

Seven bugs were found by testing against an independent reference. All are fixed in 1.0.0.

1. Download phase counted 0.0 Mbps while upload worked.
   Root cause: `URLSession.data(for:delegate:)` with a task-scoped delegate accumulates the body itself and never calls `didReceive data`, so the byte ledger stayed at zero while the transfer visibly succeeded.
   Fix: `Sources/SpeedCore/SpeedTest/Cloudflare/DownloadStream.swift` owns a session with a session-level `URLSessionDataDelegate` and counts bytes in `didReceive data`.
   Caught by: the first live run against the real endpoint.

2. `codesign --verify` rejected the app installed from the DMG with "resource fork, Finder information, or similar detritus not allowed".
   Root cause: the DMG was staged inside iCloud Drive, and the file provider tagged every file with `com.apple.fileprovider.fpfs#P` and `com.apple.FinderInfo` extended attributes, which were baked into the image.
   Fix in `scripts/make-dmg.sh`: stage in a `mktemp -d` directory outside iCloud, copy with `ditto --noextattr --noqtn`, run `xattr -cr` on the staged app, re-sign with `codesign --force --sign "$IDENTITY" --options runtime --timestamp=none`, and `codesign --verify --strict` before creating the image.
   Caught by: `codesign --verify --strict` on the installed copy.

3. `DEVELOPMENT_TEAM` was wrong.
   Root cause: the research and the plan assumed the identity's CN suffix `XB7X3VP977` was the team. The team ID is the certificate's OU, `Z6SX8L9HA7`.
   Fix: `project.yml` sets `DEVELOPMENT_TEAM: Z6SX8L9HA7`.
   Caught by: the signing step of the build.

4. The static library build failed under `ENABLE_USER_SCRIPT_SANDBOXING`.
   Root cause: the script sandbox blocked the Swift ObjC generated-header copy phase for the `SpeedCore` static library.
   Fix: the `SpeedCore` target in `project.yml` sets `SWIFT_INSTALL_OBJC_HEADER: NO` and `SWIFT_OBJC_INTERFACE_HEADER_NAME: ""`. Script sandboxing stays on.
   Caught by: the build log.

5. Menu bar number rounded and sized wrongly.
   Root cause: `NumberFormatter` defaults to banker's rounding, so 84.25 rendered as "84.2", which looks like a mismatch against the panel; and at 10 Gbps and above the "G" form produced a six-character string that broke the fixed item width.
   Fix in `Sources/SpeedCore/Support/Formatters.swift`: `roundingMode = .halfUp`, and above 10 Gbps the giga value drops its decimal. Pinned by `FormatterTests.barMagnitudes` (84.25 to "84.3") and `FormatterTests.widthBound` (never more than five characters up to 99,999 Mbps).
   Caught by: unit tests written against expected strings.

6. Launch at login silently stopped working after a reinstall.
   Root cause: registration ran only on first launch. The background task database records the bundle it registered, and replacing the bundle on reinstall left that record pointing at nothing, so `SMAppService.mainApp.status` read `.notFound`.
   Fix: `AppCoordinator.reconcileLaunchAtLogin()` runs on every launch from `/Applications` and makes the registration match the `launchAtLoginWanted` preference (default true) in `Sources/App/AppSettings.swift`. Registering again is idempotent.
   Caught by: `--login-status` after two reinstalls. Verified `enabled` after both.

7. A parser test was wrong, not the parser.
   Root cause: the synthetic route-message builder in `Tests/SpeedCoreTests/RouteMessageParserTests.swift` emitted a message whose `ifm_msglen` was shorter than `if_msghdr` itself, which the kernel never does.
   Fix: `MessageBuilder.addOtherMessage` clamps the length to at least `MemoryLayout<if_msghdr>.size`.
   Caught by: reading the failing test against the kernel's actual contract.

### Deviations from the plan

The plan is `/Users/srimi/.claude/plans/okla-i-want-to-twinkly-nygaard.md`. These are the differences that change what a verifier should expect. The code wins in every case.

| Plan said | Code does | Effect on verification |
|---|---|---|
| `DEVELOPMENT_TEAM: XB7X3VP977` | `Z6SX8L9HA7` | Bug 3 above |
| Two-line layout is the default | `BarLayout.adaptive` (one number, arrow follows the traffic) is the default; two-line, one-line and dot-only remain in Settings | Checklist item 1 |
| GO is disabled while offline or in captive-portal state | `SpeedTestController.canStart` only checks running, rate-limit backoff and the 30 s spacing | Do not expect GO to grey out during an outage |
| Confirmation sheet before testing on a metered or Low Power link | The "Ask before testing on metered or low power" toggle exists in Settings but nothing reads it; `AppCoordinator.startSpeedTest()` starts immediately | No prompt to verify |
| Panel reopens when a test finishes while closed | `StatusItemController.reopenPanelForResult()` exists but is never called; the toggle in Settings is not read | No reopen to verify |
| Notify-after, minimum-logged-duration, notify-on-drop and notify-on-restore are user settings | The Settings controls write preferences that nothing reads. The engine uses `ConnectivityStateMachine.Config` defaults: notify after 10 s, log outages of 3 s or longer. Banners are always posted unless alerts are paused | Expect 10 s and 3 s regardless of the steppers |
| Apple deep test runtime is a setting | `AppCoordinator.startAppleDeepTest()` calls `NetworkQualityRunner.run(interfaceName:)` with the default `maxSeconds` of 15; the Settings stepper is not read | Expect `-M 15` always |
| Refresh policy setting and cadence changes on power-source change | Cadence is chosen once at launch by `PowerPolicy.currentCadence()` (1 s on AC, 2 s on battery, 5 s in Low Power Mode). The refresh policy preference is not read | Plug or unplug after launch does not change cadence until relaunch |
| Notification actions "Run Speed Test" and "Show Outage Log" | `NotificationService` declares `onRunTestRequested` and `onShowLogRequested` but nothing assigns them. Tapping an action only brings the app to the foreground | Do not expect the actions to start a test |
| Pause Alerts for 1 hour or until tomorrow | `AppCoordinator.pauseAlerts(until:)` sets the engine paused and nothing schedules the un-pause. The menu title reverts after the interval, but the engine stays paused until Resume Alerts is chosen or the app relaunches. The pause is in memory only | Treat Pause Alerts as "until Resume or relaunch" |
| Probe cadence visible in `os_log` | The engine does not log individual probes. Only errors, launch, login item changes, notification authorisation, live meter binding and rebaselining are logged | Probe cadence cannot be read from the log; see Diagnostics |
| Loaded latency during throughput phases | Not implemented; `downloadLoadedLatencyMs` and `uploadLoadedLatencyMs` are always nil | Nothing to verify |
| Path-generation change aborts a test as `.networkChanged` | The error case exists but is never thrown | A network change mid-test is not detected |
| Interface override, JSON/CSV export, details disclosure on result tiles, Outage Log menu item | Not implemented. Outages live in the panel's Outages tab | Nothing to verify |
| 403/429 backoff ladder of 15 min, 1 h, 6 h | One 15 minute block (`blockedUntil`) per rate-limit error | Expect 15 minutes |
| `hdiutil create -fs HFS+` | `-fs APFS` | Cosmetic |
| Test suites including `StubURLProtocol` phase tests, prober hang test, `networkQuality` decoding, `Deadline` tests | Not present. The "sum, not average" rule is pinned by `ByteLedgerTests` and the live run only; the prober's deadline was verified by the harness, not a unit test; `NetworkQualityReport` decoding has no test | See the coverage table in Part 2 |
| M1 reinstall spike confirms the notification grant survives | The grant was never given, so persistence is unverified | "Not yet verified" |

## Part 2: How to verify a change

### Build and install

```bash
cd "/Users/srimi/Library/Mobile Documents/com~apple~CloudDocs/internet-speed-reader"
./scripts/install.sh
```

`scripts/install.sh` runs `xcodegen generate`, builds Release into `~/Library/Developer/Xcode/DerivedData/InternetSpeedReader`, quits any running copy, copies the app to `/Applications` with `ditto`, runs `codesign --verify --strict --verbose=2`, and launches it. Always install to `/Applications`: login item registration is skipped anywhere else (`LoginItemManager.isInApplicationsFolder`), and the right-click menu says "Not in /Applications (login item is fragile)".

Never run the binary through `swift run` or from the build folder for notification work; `UNUserNotificationCenter` needs a real bundle.

### Unit tests

```bash
cd "/Users/srimi/Library/Mobile Documents/com~apple~CloudDocs/internet-speed-reader"
xcodegen generate
xcodebuild -project InternetSpeedReader.xcodeproj -scheme InternetSpeedReader \
  -destination 'platform=macOS' \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/InternetSpeedReader" test
```

Expected: 75 tests in 16 suites pass. No network is needed. The menu bar agent does not launch, because `SpeedCoreTests` depends only on `SpeedCore` and has no `TEST_HOST`. If a test needs the app target, that is a design regression.

What the suites pin, so you know which one to extend:

| Suite (file) | What it pins |
|---|---|
| Active direction selector (`ActiveDirectionSelectorTests.swift`) | Download is the resting state; upload takes over only at 1.3x dominance above the 0.15 Mbps floor; 3 s dwell limits flicker |
| Active interface selector (`ActiveInterfaceSelectorTests.swift`) | Dedupe of en0, physical beats tunnel, tunnel-only fallback, `lo0`/`awdl0`/`llw0` excluded, wired preferred when listed first |
| Cloudflare metadata decoding, Response validation, Upload fixtures (`CloudflareDecodingTests.swift`) | The live `/meta` shape, the legacy shape, the 403 `{}` body; portal HTML and length mismatches are rejected; the 403 one-byte byte cap is recognised; uploads count only when the server confirms the byte count; fixtures are created once and reused; rung selection |
| Connectivity state machine (`ConnectivityStateMachineTests.swift`) | Two failures confirm, one success clears, honest start time, path debounce, satisfied path is not proof of internet, captive portal state, 10 s notify threshold, 20 s wake grace gates banners only, sleep closes the open outage, suspended ignores everything, restore banner only after a drop banner, 30 s backoff after ten failures, paused alerts, speed test suspension |
| Formatters (`FormatterTests.swift`) | Bar strings at every magnitude, MB/s division, `de_DE` comma, five-character bound, duration strings |
| Outage engine (`OutageEngineTests.swift`) | Full outage cycle with a scripted prober and a fast clock, captive portal reporting, no probes while suspended |
| Outage ledger (`OutageLedgerTests.swift`) | Persistence across reload, sub-3 s blips dropped, crash orphans closed at the heartbeat, unknown schema version moved to `.bak` |
| Route message parser (`RouteMessageParserTests.swift`) | 64-bit counters above 2^32, advancing by `ifm_msglen` through odd-length foreign messages, truncated tail, index filter, zero-length header stops the walk |
| Server timing parser, Chunk ladder, Throughput aggregator, Byte ledger (`SpeedTestMathTests.swift`) | Edge plus worker time, cold worker, cfL4 microseconds, malformed headers; 2 s per-stream sizing with 256 KiB floor and 50 MiB ceiling; 1.5 s warm-up discard, stall trimming, byte-weighted mean, insufficient data, short-sample flag; eight concurrent streams sum into one ledger |
| Support layer (`SupportTests.swift`) | `Duration.seconds`, `RingBuffer` eviction |
| Throughput calculator (`ThroughputCalculatorTests.swift`) | Rate uses measured elapsed time, counter decrease rebaselines, gaps over 5 s discarded, sub-0.2 s intervals ignored, 50 Gbps ceiling, values past the 32-bit boundary |

Not covered by unit tests: `HTTPProber` against a real or stubbed session, `LiveThroughputMonitor` scheduling, `CloudflareSpeedTest` phases against a stub server, `NetworkQualityReport` decoding, `withDeadline` on its own, and everything in `Sources/App/`.

### Isolation proof

`SWIFT_DEFAULT_ACTOR_ISOLATION` does not appear in the xcodebuild log, so grepping the log proves nothing. If you touch `project.yml`, repeat the empirical check:

1. Add a temporary file under `Sources/SpeedCore/` that declares a `@MainActor func marker() {}` and calls it from a plain synchronous function.
2. Build. Expected: the `SpeedCore` target fails with "call to main actor-isolated global function in a synchronous nonisolated context".
3. Move the same file under `Sources/App/`. Build. Expected: it compiles.
4. Delete the file.

### Manual checklist

Each item gives the action, the expected observation, and where the behaviour lives. Items marked "not yet exercised" are possible with the shipped code but were not performed during the 1.0.0 session; see the list at the end.

1. Menu bar width and placement.
   Action: install, then watch the item while idle and during a download. Change "Menu bar shows" in Settings > General between the four layouts. Hold Command and drag the item to a new position, quit and relaunch.
   Expect: the item's width never changes as the number changes (`StatusItemView.width(for:showUnits:unit:)` pins it to the widest string the formatter can produce, never more than five characters). The default layout shows one arrow and one number. The dragged position survives relaunch (`autosaveName` is `com.srimi.internetspeedreader.readout`). Dot-only draws only the dot.

2. Live meter against the kernel.
   Action: confirm the active interface in Settings > Network or the panel header (for example "Wi-Fi · en0"). In one terminal run `netstat -I en0 -b -w 1`. In another run `curl -s -o /dev/null 'https://speed.cloudflare.com/__down?bytes=52428800'`.
   Expect: netstat's per-second Ibytes column times 8 divided by 1,000,000 is the link-layer Mbps. The bar and the panel's live tile track it within a few percent, lagging a tick or two because the displayed value is an exponential average with factor 0.5 (`AppCoordinator.ingest`) refreshed every 500 ms. Both read about 10 percent above the payload rate curl reports (9.6 percent measured for 1.0.0). While the upload direction dominates by 1.3x for more than the 3 s dwell, the adaptive layout switches to the up arrow.

3. Idle reading.
   Action: leave the Mac idle for a minute.
   Expect: "0.0" or a small fraction (0.01 Mbps measured). Background chatter never flips the arrow to upload because both directions are under the 0.15 Mbps floor.

4. Interface transitions.
   Action: turn Wi-Fi off and on. Plug and unplug Ethernet if available. Connect and disconnect a VPN if available (not yet exercised).
   Expect: no negative numbers and no spikes; when the active interface changes the displayed numbers reset to zero and the monitor rebaselines (`AppCoordinator.apply`, `ThroughputCalculator` rebaselines on a counter decrease, a gap over 5 s, or a rate over 50 Gbps). The panel header names the new interface. With a VPN and a physical interface both present the physical one is counted; with a tunnel only, the header reads "VPN (utunN) · tunnel payload". The Outages tab may show a record if the transition left the path unsatisfied for more than 3 s, and banners are gated for 15 s after an interface change.

5. Speed test.
   Action: click the item, press GO. During the download phase run `lsof -i -a -p $(pgrep -x InternetSpeedReader)`. Run a test at speed.cloudflare.com in a browser within the same minute. Press Stop during a second run. Press GO twice quickly on a third.
   Expect: phases read "Finding server", "Latency", "Download", "Upload", "Finishing" and the whole run takes about 24 s at defaults (23.6 s measured; meta 4 s deadline, latency 6 s cap, 10 s download, 8 s upload, plus probes). Tiles show PING, JITTER, DOWNLOAD, UPLOAD; the row beneath shows ISP and city on the left and "Cloudflare · City (CODE)" on the right. `lsof` shows about six established connections to Cloudflare during download and four during upload, one per stream, because each stream owns a session with `httpMaximumConnectionsPerHost = 1`. The plan's tolerance for the browser cross-check is 10 to 15 percent; this was not measured for 1.0.0. Stop returns the gauge to GO at once and persists nothing. A second GO while running does nothing. After a run GO is grey for 30 s (`SpeedTestController.minimumSpacing`). While a test runs the dot is blue and the outage engine is suspended; when it ends the dot returns to green without a probe, and the next real probe is 15 s later. Memory should not grow by the upload size, because upload bodies are files under `~/Library/Caches/com.srimi.internetspeedreader/upload/`.

6. Speed test failure paths.
   Action: run a test with Wi-Fi off.
   Expect: the row under the gauge shows "No internet connection" or "Not enough data to report a reliable number" in red, no tile changes, no history row. A 403 or 429 from Cloudflare shows "Cloudflare is rate limiting. Try the Apple deep test." and blocks GO for 15 minutes. An intercepting server that answers with something other than `application/octet-stream` of exactly the requested length shows "Test blocked: …" and records no number. The interception path is pinned by `ResponseValidatorTests`; exercising it live needs a local HTTPS server the Mac trusts, because the endpoint is HTTPS and a plain `/etc/hosts` redirect fails at TLS before the validator runs (not yet exercised).

7. Outage through the path (Wi-Fi off).
   Action: with the app online for at least 10 s (launch grace), turn Wi-Fi off. Note the time.
   Expect: the dot and the numbers turn red within about 3 to 6 s. The path goes unsatisfied, the 3 s debounce runs, and the outage opens either from the next path event ("Wi-Fi is off" in the Outages row) or from two probe failures 2 s apart ("probeFailed"), whichever lands first (`ConnectivityStateMachine.handlePath`, `handleProbe`). The panel header reads "Internet is down" with "Down for …". The Outages tab shows a row marked "ongoing" whose start is the first failure, not the confirming one. Turn Wi-Fi on: the satisfied path schedules a probe 300 ms later, one success clears the outage, and the dot is green within a few seconds.

8. Outage through the probes (path stays up, internet gone).
   Action: unplug the router's uplink, or point `www.gstatic.com` and `captive.apple.com` at an unreachable address in `/etc/hosts` and flush the DNS cache (not yet exercised; the 1.0.0 session verified the prober's deadline with a harness aimed at 192.0.2.1, not through `/etc/hosts`).
   Expect: the first failure is noticed within one online probe interval (15 s) plus the 3 s round budget; the confirming failure follows 2 s plus a round later; so red within roughly 23 s worst case, and the recorded start is the first failure. While down, probes run every 2 s, backing off to 30 s after ten consecutive failures, so restore is seen within about 2 to 5 s early in an outage and within about 33 s later. "Check Connection Now" in either menu, or opening the panel, forces an immediate probe. `failureKinds` in the record lists what was seen (`dnsFailed`, `timedOut`, `deadline`, and so on).

9. Banners (needs the notification permission; not yet exercised).
   Action: click Allow on the prompt, or use the right-click menu's "Send Test Notification", which posts "Test notification. Alerts are working." Then cause an outage as in item 7 and keep it for at least 15 s, then restore.
   Expect: a banner titled "Internet connection lost" with body "<reason> on en0, since HH:MM." arrives 10 s after the outage start, provided the app has been running more than 10 s, awake more than 20 s, and on the same interface more than 15 s (grace windows gate banners only; the record is written immediately). On restore, "Internet is back" with "Restored after 4m 12s, down since HH:MM." replaces the drop banner, which is removed from Notification Center. No restore banner appears if the drop banner never fired. There is no sound. Outages under 3 s are dropped from the log. The right-click menu's "Notifications:" line and Settings > Alerts > Permission both read "allowed".

10. Pause Alerts.
    Action: right-click, Pause Alerts, 1 Hour. Cause an outage longer than 10 s.
    Expect: the bar still goes red and the Outages tab still records; no banner. The menu item reads "Alerts Paused". Choose Resume Alerts to re-arm. The engine does not un-pause on its own when the hour ends, and the pause is forgotten on relaunch.

11. Sleep and wake.
    Action: close the lid for two minutes and open it. Separately, switch between two Wi-Fi networks.
    Expect: no banner on wake; no throughput spike (the monitor pauses on `willSleepNotification`, rebaselines on `didWakeNotification`, and any gap over 5 s is discarded); no outage record spanning the sleep (an outage that was open at sleep is closed with `endReason` `sleep`). After wake the engine probes 2 s later and banners are gated for 20 s. Switching Wi-Fi networks on the same en0 relies on the 3 s path debounce: a switch shorter than 3 s leaves nothing, a longer one may log a record, and only one that lasts past 10 s produces a banner. An overnight sleep was not exercised.

12. Captive portal (not yet exercised).
    Action: join a network with a sign-in page.
    Expect: the primary HEAD to `www.gstatic.com/generate_204` does not return 204, the fallback GET to `captive.apple.com/hotspot-detect.html` answers without "Success" in the body, and the state becomes captive portal: red dot and numbers, header "Sign-in required", subtitle "This network wants you to sign in first", an Outages row with "Captive portal detected", probes every 2 s. GO stays enabled (deviation from the plan). After signing in, the next successful probe clears it.

13. Force quit during an outage.
    Action: while the Outages tab shows an "ongoing" row, run `kill -9 $(pgrep -x InternetSpeedReader)`, then relaunch.
    Expect: `~/Library/Application Support/com.srimi.internetspeedreader/outages.json` shows that record closed with `"endReason": "crash"` and an `end` equal to the last heartbeat, which is written to the `com.srimi.internetspeedreader.lastAlive` default every 60 s. A normal Quit closes it with `"quit"` instead (`AppCoordinator.shutdown` waits up to 1.5 s for the ledger). Pinned by `OutageLedgerTests.closesCrashOrphans`; not yet exercised live.

14. Apple deep test.
    Action: right-click, Apple Deep Test (also in the panel's gear menu). On a second run press Stop, then run `pgrep -l networkQuality`.
    Expect: the app spawns `/usr/bin/networkQuality -c -s -M 15` plus `-I <interface>`; the source comment says a run asked to stop at 15 s takes 17 to 19 s, and the hard stop is 25 s followed by SIGKILL 2 s later. During the run the dot is blue and the gauge shows the phase without a live number. Tiles relabel to BASE RTT, RPM, DOWNLOAD, UPLOAD; the server row reads "Apple CDN · <test_endpoint>"; the History row is tagged "Apple". The Apple base RTT is never written into `pingMs`. After Stop, `pgrep` prints nothing. No measurement of an Apple run is recorded for 1.0.0.

15. Persistence and clearing.
    Action: run a test, cause an outage, quit, relaunch. Then use Settings > Network > "Clear test history" and "Clear outage log".
    Expect: History and Outages tabs repopulate from `speedtests.json` (cap 200) and `outages.json` (cap 500) under `~/Library/Application Support/com.srimi.internetspeedreader/`; the latest result tiles are restored. Each file is a JSON envelope `{"version": 1, "records": […]}` with ISO 8601 dates. A file with an unknown version is renamed to `.bak` and the app starts empty rather than crashing. The clear buttons empty both the UI and the files.

16. Launch at login.
    Action: install to `/Applications` and launch. Open System Settings > General > Login Items & Extensions. Run the `--login-status` command from Diagnostics. Turn the toggle off in Settings > General, check again, turn it back on. Reinstall twice with `scripts/install.sh` and check again. Log out and back in (not yet exercised).
    Expect: the app is listed in Login Items; `--login-status` prints `login item: enabled`. Off prints `disabled` (the mapping of `.notRegistered`) and removes the entry. After each reinstall it still prints `enabled`, because `reconcileLaunchAtLogin` re-registers on every launch when `launchAtLoginWanted` is true (verified twice for 1.0.0). If the system reports `requiresApproval`, Settings shows "Approval is needed in System Settings" with an "Open Login Items" button, and the right-click item reads "Launch at Login (approve in System Settings)".

17. Notification grant across reinstall (not yet exercised).
    Action: after Allow, reinstall twice and check the right-click menu's "Notifications:" line.
    Expect: "allowed" without a new prompt, because the Apple Development signature gives a stable designated requirement. If it reverts to "not asked yet", the signing setup has regressed.

18. Accessibility and appearance.
    Action: turn on VoiceOver and move to the status item and the gauge. Turn on Reduce Motion. Switch between light and dark wallpapers.
    Expect: the status item reads label "Internet speed" and a value such as "Downloading at 84.2 Mbps, online" in the adaptive layout or "Download 84.2, upload 12.1 Mbps, online" otherwise (`StatusItemView.updateAccessibility`). The GO button is labelled "Start speed test". With Reduce Motion the gauge arc no longer eases (`GaugeView`). Text uses `labelColor` and red uses `systemRed`, so both appearances stay legible.

19. Disk image.
    Action: `./scripts/make-dmg.sh`. Then:
    ```bash
    hdiutil attach dist/InternetSpeedReader-1.0.0.dmg
    ls "/Volumes/Internet Speed Reader"
    codesign --verify --strict --verbose=2 "/Volumes/Internet Speed Reader/InternetSpeedReader.app"
    ```
    Drag the app to `/Applications`, then `codesign --verify --strict --verbose=2 /Applications/InternetSpeedReader.app` and `xattr -lr /Applications/InternetSpeedReader.app`, then launch.
    Expect: the volume is named "Internet Speed Reader" and holds `InternetSpeedReader.app`, an `Applications` symlink and `READ ME FIRST.txt`; `hdiutil verify` passed inside the script; both `codesign` checks pass; `xattr` lists no `com.apple.FinderInfo` or `com.apple.fileprovider` entries (the regression for bug 2); the installed app launches and, on a machine that has never answered, shows the notification prompt. The script prints the image size and SHA-256. A rebuilt image will not match the release hash; only the downloaded release asset is expected to hash to `4b11408d3d5d5c8e9d99d45311e8f3eb874048346fe0228d3e9609e353282f46`. `dist/` is git-ignored.

20. Uninstall (not yet exercised).
    Action: `./scripts/uninstall.sh`.
    Expect: the script quits the app, runs the bundled binary with `--unregister-login-item` before deleting it (the login item database keys off the bundle), removes `/Applications/InternetSpeedReader.app`, `~/Library/Application Support/com.srimi.internetspeedreader`, `~/Library/Caches/com.srimi.internetspeedreader`, and the defaults domain. Afterwards `defaults read com.srimi.internetspeedreader` reports that the domain does not exist and Login Items no longer lists the app.

### Diagnostics

| Purpose | Command | What to expect |
|---|---|---|
| Login item state without starting the agent | `/Applications/InternetSpeedReader.app/Contents/MacOS/InternetSpeedReader --login-status` | Prints `login item: enabled` (or `disabled`, `requiresApproval`, `notFound`) and `bundle: /Applications/InternetSpeedReader.app`, then exits. Must be run from inside the installed bundle |
| Register or unregister the login item by hand | the same binary with `--register-login-item` or `--unregister-login-item` | Prints the outcome and exits |
| Live log | `log stream --level debug --predicate 'subsystem == "com.srimi.internetspeedreader"'` | Categories `app`, `live`, `outage`, `speedtest`. Messages include "Internet Speed Reader launched", "live meter bound to en0 (index N)", "rebaselining live meter: staleGap" (debug level, so `--level debug` is required), "login item set to true, state=enabled", "notification authorization granted=true", "meta lookup failed, ISP will fall back: …", and ledger persistence errors. Individual probes are not logged |
| Log after the fact | `log show --last 1h --info --debug --predicate 'subsystem == "com.srimi.internetspeedreader"'` | Same messages. Without `--info` (and `--debug` for the rebaseline line) `log show` hides everything except the five `Logger.error` calls |
| Preferences | `defaults read com.srimi.internetspeedreader` | Keys are written only once changed: `barLayout`, `unit`, `showUnits`, `refreshPolicy`, `notifyOnDrop`, `notifyOnRestore`, `notifyAfterSeconds`, `minimumOutageSeconds`, `downloadStreams`, `uploadStreams`, `phaseSeconds`, `dataSaver`, `confirmOnMetered`, `appleMaxSeconds`, `reopenPanelOnFinish`, `launchAtLoginWanted`. The heartbeat `com.srimi.internetspeedreader.lastAlive` is written every 60 s while the app runs |
| Outage log and test history on disk | `python3 -m json.tool ~/Library/Application\ Support/com.srimi.internetspeedreader/outages.json` and `speedtests.json` in the same folder | Versioned envelopes, sorted keys, ISO 8601 dates |
| Kernel oracle for the live meter | `netstat -I en0 -b -w 1` | Per-second interface bytes; multiply by 8 and divide by 1,000,000 for Mbps. This is the same 64-bit counter path the app reads |
| Connections during a test | `lsof -i -a -p $(pgrep -x InternetSpeedReader)` | About six connections in the download phase, four in the upload phase |
| Leftover Apple test process | `pgrep -l networkQuality` | Empty after Stop or completion |
| Signature | `codesign --verify --strict --verbose=2 /Applications/InternetSpeedReader.app` | Passes; `codesign -dvv` on the same path shows the Apple Development identity and team `Z6SX8L9HA7` |
| Extended attributes that break signing | `xattr -lr /Applications/InternetSpeedReader.app` | No `com.apple.FinderInfo` or `com.apple.fileprovider` entries |
| Image integrity | `hdiutil verify dist/InternetSpeedReader-1.0.0.dmg` and `shasum -a 256 dist/InternetSpeedReader-1.0.0.dmg` | Verify passes; the hash matches the release only for the downloaded asset |

### Not yet verified

These are honest gaps at the time of the 1.0.0 release. None was tested; do not assume they work.

- No screenshot of the status item exists. Chrome was fullscreen during the session and hid the menu bar.
- The notification prompt appeared but Allow was not clicked. Drop and restore banners, "Send Test Notification", and persistence of the grant across reinstalls are all unverified end to end.
- No VPN was connected. The physical-beats-tunnel and tunnel-only rules are covered by unit tests only.
- No captive portal was joined.
- No overnight soak. Memory and CPU over hours, and behaviour across a long sleep, are unmeasured.
- No test on a second Mac. The Gatekeeper first-launch flow described in `READ ME FIRST.txt` and the README has not been exercised on a machine other than the build host.
- No live interception test against a local HTTPS server.
- No log out and back in to see the login item launch the app.
- No recorded Apple deep test run, cross-check against speedtest.net, memory measurement during upload, force-quit rehearsal, or uninstall run.
