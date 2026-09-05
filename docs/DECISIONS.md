# Architecture decision records

These records describe the current v1.1.0 design. Updated records explicitly replace the earlier method where behavior changed. Historical measurements and research remain context, not evidence that this version passed live acceptance. See [VERIFICATION-1.1.md](VERIFICATION-1.1.md) for current validation and [VERIFICATION.md](VERIFICATION.md) for the untouched v1.0 record. Earlier plans are history; current source is authoritative.

Paths are relative to the repository root. Measurements came from one development
environment and one network. They illustrate the reasoning; they are not universal
constants. Personal host and network metadata is intentionally excluded.

| ADR | Decision | Primary file |
|---|---|---|
| 001 | AppKit `NSStatusItem` with a custom `NSView`, not SwiftUI `MenuBarExtra` | `Sources/App/StatusBar/StatusItemController.swift` |
| 002 | Cloudflare for on-demand capacity, Apple as a separate second opinion | `Sources/SpeedCore/SpeedTest/Cloudflare/CloudflareSpeedTest.swift` |
| 003 | 64-bit kernel byte and packet counters | `Sources/SpeedCore/Counters/RouteMessageParser.swift` |
| 004 | One physical interface, with path-use evidence and no VPN double counting | `Sources/SpeedCore/Path/PathSnapshot.swift` |
| 005 | One ephemeral URLSession per transfer stream | `Sources/SpeedCore/SpeedTest/Cloudflare/CloudflareSpeedTest.swift` |
| 006 | Session-level transfer delegate with cancellation through completion | `Sources/SpeedCore/SpeedTest/Cloudflare/DownloadStream.swift` |
| 007 | Separate provisional progress from confirmed payload | `Sources/SpeedCore/SpeedTest/Cloudflare/PhaseMeasurement.swift` |
| 008 | Per-stream sizing within shared time and byte budgets | `Sources/SpeedCore/SpeedTest/Cloudflare/ChunkLadder.swift` |
| 009 | Methodology 2: measured payload/time, warm-up excluded, stalls retained | `Sources/SpeedCore/SpeedTest/Cloudflare/ThroughputAggregator.swift` |
| 010 | Subtract server processing from HTTP latency only | `Sources/SpeedCore/SpeedTest/Cloudflare/ServerTiming.swift` |
| 011 | Validate completed transfers before accepting payload | `Sources/SpeedCore/SpeedTest/Cloudflare/ResponseValidator.swift` |
| 012 | File-backed random upload fixtures with exact reservation sizes | `Sources/SpeedCore/SpeedTest/Cloudflare/UploadFixture.swift` |
| 013 | Keep actual interface traffic distinct from capacity tests | `Sources/App/StatusBar/StatusItemController.swift` |
| 014 | Outage hysteresis: two failures down, one success up, 3 s path debounce | `Sources/SpeedCore/Outage/ConnectivityStateMachine.swift` |
| 015 | Grace windows gate banners, not the ledger; sleep closes; heartbeat | `Sources/SpeedCore/Outage/OutageLedger.swift` |
| 016 | HTTP probes under one 3 s round deadline, no ICMP, no gateway | `Sources/SpeedCore/Probe/ConnectivityProbe.swift` |
| 017 | Measured monotonic time, cadence-aware freshness and live power updates | `Sources/SpeedCore/Support/Deadline.swift` |
| 018 | Sustained upload priority, with an explicit control-packet heuristic | `Sources/SpeedCore/Counters/ActiveDirectionSelector.swift` |
| 019 | Bar strings: half-up rounding, five characters max, pinned width | `Sources/SpeedCore/Support/Formatters.swift` |
| 020 | Alerts are banner plus red bar plus log, no sound, `.active` level | `Sources/App/NotificationService.swift` |
| 021 | Launch at login on by default, reconciled on every launch | `Sources/App/AppCoordinator.swift` |
| 022 | Versioned atomic history with additive method metadata | `Sources/SpeedCore/Support/AtomicJSONStore.swift` |
| 023 | Local signing configuration and public build privacy | `project.yml` |
| 024 | Deployment target macOS 14 | `project.yml` |
| 025 | Swift 6 language mode with per-target default actor isolation | `project.yml` |
| 026 | Repository inside iCloud Drive, build products outside it | `scripts/make-dmg.sh` |
| 027 | UDZO disk image on APFS, staged outside iCloud, app and image signed | `scripts/make-dmg.sh` |
| 028 | Run ownership through cancellation and cleanup | `Sources/SpeedCore/Support/SpeedTestRunGate.swift` |

---

## ADR-001: AppKit `NSStatusItem` with a custom `NSView`, not SwiftUI `MenuBarExtra`

**Context.** The menu bar item must draw a coloured dot plus a number in a fixed width, distinguish left click from right click, open and close its panel from code (so that a test finishing while the panel is closed can reopen it — the hook `StatusItemController.reopenPanelForResult()` exists but is not yet called), and keep its position across launches. The research checked `MenuBarExtra` against the MacOSX 26.5 SDK `swiftinterface`: its label is limited to `Text` or `Label<Text, Image>`, it has no API to present or dismiss its window, no click-type distinction, and no access to the underlying `NSStatusItem`. macOS 26 added nothing to it. `NSStatusItem` is not deprecated; only its pre-10.14 forwarding shims are.

**Decision.** `StatusItemController` creates `NSStatusBar.system.statusItem(withLength: 72)`, hosts `StatusItemView` (an `NSView` subclass) as a subview of the button, routes `sendAction(on: [.leftMouseUp, .rightMouseUp])` through one handler, and shows a `.transient` `NSPopover` whose content is `PanelView` inside an `NSHostingController`. `autosaveName` is `com.srimi.internetspeedreader.readout`. SwiftUI is still used for the panel, the gauge and the `Settings` scene, which is the only SwiftUI scene in `Sources/App/InternetSpeedReaderApp.swift`.

**Consequences.** Click routing, button highlighting, and the assign-then-clear dance for the context menu (`statusItem.menu = menu`, `performClick`, then `menu = nil` in `menuDidClose`) are hand written. The two-line layout is drawn directly rather than through `attributedTitle`, which the research reports clips and needs per-display baseline offsets. Placement next to the clock cannot be programmed on macOS; the README documents Command-drag and the autosave name makes the choice stick.

**Evidence.** `Sources/App/StatusBar/StatusItemController.swift` (header comment and `handleClick`), `Sources/App/StatusBar/StatusItemView.swift`. Research report, topic 2, verified items 2, 3, 4 and 7. The critique notes that the open Feedback Assistant bugs cited for `MenuBarExtra` date from 2022 to 2023 and were not re-tested on macOS 26.6; the label-type restriction, which is sufficient on its own, was verified in the SDK.

---

## ADR-002: Cloudflare for on-demand capacity, Apple as a separate second opinion

**Decision.** GO uses Cloudflare's public endpoints. Apple Deep Test uses the installed `/usr/bin/networkQuality` tool. Live monitoring starts independently and does not schedule capacity tests. Provider, timestamp and quality identify a result; methods and servers can legitimately disagree with Ookla.

**Consequences.** Cloudflare metadata supplies ISP/location when available, otherwise the UI uses an explicit fallback. Only HTTP 429 blocks that engine for 15 minutes; HTTP 403 is an explicit server refusal of unknown cause. Apple remains separate after shared run spacing. Loaded-latency fields remain unpopulated. The existing metered-confirmation preference is still unwired and must not be advertised as protection.

**Evidence.** `CloudflareSpeedTest`, `NetworkQualityRunner`, `SpeedTestController`, `PanelView`. The earlier provider research explains the original choice; it does not establish current provider performance or API guarantees.

---

## ADR-003: 64-bit kernel byte and packet counters

**Decision.** Keep `NET_RT_IFLIST2` and `if_data64`. `IFCounters` now carries `rx`, `tx` and `txPackets`; `RouteMessageParser` reads `ifi_ibytes`, `ifi_obytes` and `ifi_opackets`. It walks message lengths and performs unaligned loads. A backwards byte or packet counter invalidates the baseline.

**Reason.** The v1.0 investigation demonstrated 32-bit byte-counter wrap. Packet totals provide a local, permission-free control-traffic allowance without packet capture. They are aggregate statistics, not protocol or application attribution.

**Evidence.** Counter/parser code and `RouteMessageParserTests`, including values above the 32-bit boundary. Historical measurements remain in the v1.0 verification report.

---

## ADR-004: One physical interface, with path-use evidence and no VPN double counting

**Decision.** Deduplicate by index and exclude loopback/Apple peer-to-peer interfaces. Prefer physical candidates whose type is used by `NWPath`, then another physical candidate, then a tunnel. Preserve path order for same-type ties and label tunnel fallback. Never add tunnel bytes to the underlying physical bytes.

**Consequences.** `usesInterfaceType` improves selection among Wi-Fi/Ethernet candidates but does not identify an exact route among same-type adapters. Native `NWPath` equality suppresses duplicate callbacks; generation advances when the native path changes, including same-adapter route changes. Such changes invalidate live baselines and interrupt an active capacity test.

**Evidence.** `NWPathSource`, `PathSnapshot`, `ActiveInterfaceSelectorTests`; actual VPN and multi-adapter coverage is recorded separately in the versioned verification report.

---

## ADR-005: One ephemeral URLSession per transfer stream

**Decision.** Production `URLSessionCloudflareTransport` creates one session per stream, with `httpMaximumConnectionsPerHost = 1`, no cache, identity encoding and explicit deadlines. Store the negotiated network protocol when available; do not assume it remains HTTP/1.1.

**Reason.** Stream isolation makes connection ownership and cancellation explicit and avoids a shared session silently changing effective concurrency. The initial request on each stream shares its phase's time/data budget.

**Evidence.** `StreamDelegates.swift`, `DownloadStream`, `CloudflareSpeedTest.makeSessionConfiguration` and injected transport tests.

---

## ADR-006: Session-level transfer delegate with cancellation through completion

**Decision.** `DownloadStream` owns its session and pending request identity for both downloads and file-backed uploads. Cancellation records state even if it arrives before continuation installation, cancels the URL task, and finishes through its completion callback. Redirects and validation failures cannot become ordinary successful measurements.

**Reason.** A task-scoped `data(for:delegate:)` delegate did not receive download data callbacks during v1.0 development. Merely dropping a Swift task also cannot prove network cleanup is finished.

**Evidence.** `DownloadStream`, transfer tests and the historical zero-download regression in `VERIFICATION.md`.

---

## ADR-007: Separate provisional progress from confirmed payload

**Decision.** `ByteLedger` drives the live gauge only. Each request records bytes and original callback times in `RequestPayloadTimeline`; `ConfirmedPayloadLedger` commits that timeline only after request validation succeeds and its byte total matches the receipt. All streams share one phase timeline.

**Consequences.** Failed/unconfirmed requests can affect provisional progress but never the saved headline. Confirming an upload does not move all its bytes to acknowledgement time. The recorded transfer timeline retains empty intervals, stalls and the final partial interval. Shared `PhaseByteBudget` reservations include in-flight requests, preventing streams from overshooting the cap together.

**Evidence.** `PhaseMeasurement.swift`, `CloudflareSpeedTest.runPhase` and phase/ledger regression tests. This supersedes using the provisional shared ledger as final result evidence.

---

## ADR-008: Per-stream sizing within shared time and byte budgets

**Decision.** A stream starts with a small probe that can finish on slow links and sizes subsequent requests for roughly two seconds at its own measured rate. Download chunks retain a conservative 50 MiB client ceiling after earlier larger requests were refused; this is not a published endpoint limit. Later 16 MiB requests also received HTTP 403, whose cause remains unknown (see [current verification](VERIFICATION-1.1.md)). Upload uses bounded fixture rungs. A final reservation may be smaller than the preferred size and is sent at that exact size.

**Consequences.** Probes consume the same phase budget. Stop admitting requests at the configured duration and allow a bounded 2-second drain for in-flight completion. Exclude unfinished transfers, include the measured drain time, and label the result incomplete if enough confirmed measurement remains. Data-limited runs carry a separate quality label.

**Evidence.** `ChunkLadder`, `UploadFixture`, `PhaseByteBudget`, `CloudflareSpeedTest.runPhase` and their tests. Never divide an already per-stream rate by the stream count again.

---

## ADR-009: Methodology 2: measured payload/time, warm-up excluded, stalls retained

**Decision.** Exclude the first 1.5 seconds, then divide confirmed payload by actual remaining measurement time. Weight slices by their durations and keep zero-rate stalls and the partial tail. The former lowest-30%/highest-10% trimming is removed. Store full-phase mean and a one-second-window peak separately from the headline.

**Consequences.** At least one second with usable positive measurement is required. Quality is incomplete, dataLimited, shortSample (under 3 seconds), variable (one-second-window coefficient of variation above 0.25), or good, in that precedence. Windowing avoids interpreting callback coalescing as network variation. New results carry `methodologyVersion = 2`; older results are preserved, not silently recalculated.

**Evidence.** `ThroughputAggregator`, confirmed timeline/phase tests and `SpeedTestResult`. Earlier trimmed results and their original verification remain historical observations, not method-2 benchmarks.

---

## ADR-010: Subtract server processing from HTTP latency only

**Decision.** Parse `Server-Timing`, subtract server processing from HTTP timing and retain the median/jitter calculation. Store server-measured TCP minimum RTT separately when present. Throughput time is never reduced by server timing.

**Consequences.** This measures HTTP latency to the test provider, not ICMP latency or a guarantee of matching another speed-test site. A different server, route or method can produce a different result. The metadata and timing endpoints remain deadline-bound and cancellation-aware.

**Evidence.** `ServerTiming`, `CloudflareSpeedTest.measureLatency` and parser/math tests. The v1.0 latency study is retained in historical verification.

---

## ADR-011: Validate completed transfers before accepting payload

**Decision.** Downloads require status/content-type/content-length validation and exact actual received body length. Uploads require an exact positive `cf-meta-upload-bytes` confirmation and matching sent progress. Reject redirects, malformed metadata, truncated bodies and unconfirmed uploads. Interception/rate-limit errors abort the run; a cancelled run never writes success.

**Consequences.** Strict validation can produce an error where a looser client would show a misleading number. `uploadBytes` and `uploadVerifiedBytes` in method-2 Cloudflare results both describe confirmed payload; provisional bytes are not substituted for them.

**Evidence.** `ResponseValidator`, `DownloadStream`, `CloudflareSpeedTest` and transport/phase tests.

---

## ADR-012: File-backed random upload fixtures with exact reservation sizes

**Decision.** Use random file-backed bodies with explicit content length. Fixture rungs include small bodies for slow links and remain bounded at 32 MiB. A smaller final budget reservation is sent at its exact size rather than rounded up. Prepare fixtures serially before the measured phase so file generation does not distort transfer timing. Files are cached by byte size under the application's upload cache directory.

**Consequences.** The transport does not retain a whole upload body as request Data. Fixture generation still allocates its bounded file contents temporarily, and arbitrary final reservations can add cache files; do not claim a constant cache cap or flat measured memory use. Uninstall removes the cache.

**Evidence.** `UploadFixture`, `DownloadStream` and fixture/reservation tests. Live resource measurements belong in the verification report.

---

## ADR-013: Keep actual interface traffic distinct from capacity tests

**Decision.** The bar and live panel show all-app traffic on the chosen interface, including protocol overhead, retransmissions and potentially local traffic. GO shows the test's validated payload capacity. Idle is a real near-zero download reading; missing/stale data shows `—`. Last-test timestamp/provider and quality remain separate from live readings.

**Consequences.** There is no fixed percentage conversion and no reason to scale one number toward another. Protocol, route, background activity, timing and server differences all affect comparisons. Counters are never treated as proof of working internet, because LAN traffic can continue during a WAN outage.

**Evidence.** Status-item/panel rendering, README, throughput freshness tests. Earlier overhead measurements illustrate particular runs only and are retained in the historical verification report.

---

## ADR-014: Outage hysteresis: two failures down, one success up, 3 s path debounce

**Context.** A single failed probe is not an outage; a transient DNS hiccup or a slow response would otherwise turn the bar red several times a day. A satisfied `NWPath` is not proof of internet either: a captive portal where the user chose "Use Without Internet" reports `.satisfied` with no connectivity. An unsatisfied path is trustworthy in the negative direction, but Wi-Fi roaming between access points unsatisfies it for a moment.

**Decision.** `ConnectivityStateMachine` is a pure value type driven by events with `now` and `wallClock` passed in. Two consecutive probe failures (`failuresToConfirm = 2`) open an outage; one success closes it. The outage `start` is stamped at the first failure, not the confirming one, so the duration is honest. A `.satisfied` path only schedules a probe 300 ms later. An `.unsatisfied` path opens an outage after `pathDebounce = 3 s`. A captive portal is its own state with its own `OutageCause`. Probe cadence is 15 s online, 2 s while suspect or down, and 30 s after ten consecutive failures.

**Consequences.** Detection depends on the current probe cadence and each round deadline. Recovery occurs on the first successful probe. The pure state machine has hand-driven tests for the honest start stamp, debounce, captive portal state and cadence backoff. `OutageEngine` only supplies time, probes, timers and the ledger.

**Evidence.** `Sources/SpeedCore/Outage/ConnectivityStateMachine.swift` (`Config`, `handlePath`, `handleProbe`), `Sources/SpeedCore/Outage/OutageEngine.swift`, `Tests/SpeedCoreTests/ConnectivityStateMachineTests.swift`. Research report, topic 3, "fromDocs" item 6 and gotcha 3 (satisfied path is not internet), recommendation section 3 (asymmetric hysteresis).

---

## ADR-015: Grace windows gate banners, not the ledger; sleep closes the open outage; heartbeat for crash orphans

**Context.** Closing the lid, waking, switching interfaces and launching all produce probe failures that are not outages worth a banner, but they are still real intervals without connectivity that a log should not lie about. An outage that is open when the machine sleeps cannot be timed honestly across a sleep the app was not awake for. A crash or force quit during an outage would otherwise leave a record open forever, showing an eternal "ongoing" outage after relaunch.

**Decision.** `graceUntil` is set to 20 s after wake, 15 s after an interface change and 10 s after launch, and `handleTick` checks it only when deciding whether to emit `.notifyDown`; `.openOutage` is emitted regardless. `.willSleep` closes any open outage with `OutageEnd.sleep` and moves to `.suspended(.sleep)`, where every path, probe and tick event is ignored until `.didWake`. `OutageEngine.startHeartbeat` writes `lastAlive` to `UserDefaults` every 60 s; `OutageLedger.load` closes any still-open record at that timestamp with `OutageEnd.crash`. A clean quit closes with `OutageEnd.quit` through `shutdown()`. Outages shorter than 3 s are dropped at close. Notifications fire only after `notifyAfter = 10 s` of confirmed outage.

**Consequences.** The outage log is honest during grace and during paused alerts, while banners stay quiet. Dark wakes under Power Nap cannot generate phantom outages because the engine does not probe while suspended. The restore banner fires only if a drop banner did, so a silent outage does not produce a lone "Internet is back".

**Evidence.** `Sources/SpeedCore/Outage/ConnectivityStateMachine.swift` (`handleTick`, `.willSleep`, `resume`), `Sources/SpeedCore/Outage/OutageLedger.swift` (`closeCrashOrphans`, `heartbeat`, `close`), `Sources/SpeedCore/Outage/OutageEngine.swift` (`runProbe`, `startHeartbeat`, `shutdown`). Tests: `wakeGraceGatesBannersOnly`, `sleepClosesOutage`, `suspendedIgnoresEvents`, `upOnlyAfterDown` in `Tests/SpeedCoreTests/ConnectivityStateMachineTests.swift`; `closesCrashOrphans` in `Tests/SpeedCoreTests/OutageLedgerTests.swift`. Critique, "missing" item 16.

---

## ADR-016: HTTP probes under one 3 s round deadline, no ICMP, no gateway

**Context.** The research disagreed on ICMP: one report verified that `SOCK_DGRAM` ICMP works without root, another said to avoid ICMP entirely, and the critique noted that a socket opening is not the same as an echo reply arriving (the kernel rewrites the identifier on datagram ICMP sockets). Probing the default gateway is local-network traffic under Apple's definition and would trigger the Local Network privacy prompt. `NWConnection` and `URLSession` can stay silent on a blackholed route: a connection to `192.0.2.1:443` produced no state callback for over four seconds. A cached 204 or a session that waits for connectivity would report "up" without touching the network.

**Decision.** `HTTPProber` uses one long-lived ephemeral session with `waitsForConnectivity = false`, a 2 s request timeout, and no cache. A round is a `HEAD https://www.gstatic.com/generate_204` that must return exactly 204, then on failure a `GET http://captive.apple.com/hotspot-detect.html` whose body must contain "Success". The primary gets `primaryBudget = 1.5 s`; the fallback gets whatever remains of `roundBudget = 3 s`. A 200 without "Success" is `.captivePortal`. The fallback stays on plain HTTP on purpose, with an App Transport Security exception for `captive.apple.com` in `Support/Info.plist`, because an intercepting portal answers plain HTTP with its own page.

**Consequences.** Offline is declared only when both endpoints fail, so a Google outage alone does not read as an internet outage. A blackholed route fails at the round budget rather than at a URLSession timeout. There is no ICMP code to maintain and no Local Network prompt.

**Evidence.** `Sources/SpeedCore/Probe/ConnectivityProbe.swift`, `Support/Info.plist`. Prober measurements on 2026-09-04: healthy 216 ms cold then 46 to 49 ms warm; blackholed `192.0.2.1` failed via the deadline at 3003 to 3006 ms. Research report, topic 3, verified items 13, 15 and 17, "fromDocs" items 1 and 3, gotcha 7. Critique, "risky" item 8 (ICMP) and "contradictions" on ICMP policy.

---

## ADR-017: Measured monotonic time, cadence-aware freshness and live power updates

**Decision.** Retain injected `TimeSource` and explicit deadlines. Live sampling defaults to one second while awake. Missing/unknown/legacy panel-only refresh preferences migrate to `always`; explicit battery reduction stays 1/2/5 seconds for AC/battery/Low Power Mode. Observe both power-source and Low Power Mode changes, and react to preference changes immediately.

**Reason.** The v1.0 fixed five-second stale threshold rejected normal five-second low-power ticks after scheduling tolerance. The threshold is now `max(5, 3 × expectedIntervalSeconds)`; rates still divide by measured elapsed time. Missing counters and unexpected gaps publish unavailable state and recover with a fresh baseline.

**Consequences.** App Nap opt-out remains `.userInitiatedAllowingIdleSystemSleep`, with the plist backup; normal sleep is allowed. Sleep/wake/network changes clear display history. The status refresh checks freshness independently. Neither panel visibility nor GO controls sampling.

**Evidence.** `ThroughputCalculator`, `LiveThroughputMonitor`, `LiveRefreshPolicy`, `PowerPolicyObserver` and fake-clock/counter tests, including the reproduced 5.25-second regression. See current verification for installed behavior.

---

## ADR-018: Sustained upload priority, with an explicit control-packet heuristic

**Decision.** The adaptive bar rests on download. Activity is estimated from transmitted bytes beyond 160 bytes per transmitted packet, using measured elapsed time. Enter upload at 0.15 Mbps for 2 seconds, exit below 0.075 Mbps for 3 seconds, and return to download immediately when both raw directions are below 0.15 Mbps. Upload need not dominate a concurrent download.

**Consequences.** The allowance only classifies direction; displayed Mbps remains the measured byte rate. This cannot perfectly identify upload intent: many ACKs can hide a small simultaneous upload, and VPN/QUIC/offload behavior can affect it. Both directions remain visible in the panel. A measured-time smoother uses a one-second half-life, snaps idle/background values to their raw reading and resets on lifecycle changes.

**Evidence.** `ActiveDirectionSelector`, `ThroughputSmoother`, packet-counter/parser tests and direction tests. This replaces v1.0's 1.3× dominance rule and fixed three-second dwell.

---

## ADR-019: Bar strings: half-up rounding, five characters max, pinned width

**Context.** The right side of the menu bar shuffles if the item's width changes every second. Monospaced digits equalise glyph widths but not string lengths, so "9.8" and "84.2" still differ. During the build, `NumberFormatter`'s default banker's rounding turned 84.25 into "84.2", which looked like a bug next to the panel, and values at or above 10 Gbps produced a six-character string that broke the fixed width.

**Decision.** `SpeedFormatter.bar` uses `roundingMode = .halfUp`, one decimal below 100, integers below 1000, and "1.2G" style above, dropping the decimal above 10 Gbps so the string never exceeds five characters. `StatusItemView.width(for:showUnits:unit:)` measures the widest strings `SpeedFormatter.widestBarSamples` can produce and pins `statusItem.length` to that, recomputed only when layout, unit or the units toggle changes. Locale decimal separators come from `NumberFormatter`.

**Consequences.** The bar never resizes during normal operation. `FormatterTests.widthBound` asserts the five-character bound across magnitudes from 0 to 99,999 Mbps, and `barMagnitudes` pins "84.3" for 84.25.

**Evidence.** `Sources/SpeedCore/Support/Formatters.swift`, `Sources/App/StatusBar/StatusItemView.swift` (`width`, `widestNumber`), `Tests/SpeedCoreTests/FormatterTests.swift`. Session fact: bug 5. Research report, topic 2, verified item 21 and gotcha 6.

---

## ADR-020: Alerts are banner plus red bar plus log, no sound, `.active` interruption level

**Context.** The user asked for a notification banner, a red menu bar item and an outage log, and explicitly no sound. `UNUserNotificationCenter` only works from a real `.app` bundle with a signature, and the `.timeSensitive` interruption level needs an Apple-granted entitlement this project does not have, so a Focus mode can hide the banner. `.criticalAlert` likewise needs an entitlement and can fail the whole authorization request.

**Decision.** `NotificationService.requestAuthorization` asks for `[.alert]` only. Every notification sets `content.sound = nil` and `interruptionLevel = .active`. The drop notification uses identifier `isr.outage.down`; the restore notification uses `isr.outage.up` and removes the delivered drop notification first so the pair collapses. A category `OUTAGE` carries "Run Speed Test" and "Show Outage Log" actions. The delegate is set in `bootstrap()` during `applicationDidFinishLaunching`, before it returns. The red state colours the dot and the text in `StatusItemView` and does not depend on notification permission. Settings says plainly that Focus modes can hide banners and that the red bar always shows.

**Consequences.** Users who never grant notification permission still get the red bar and the log. Alerts can be paused for an hour or until tomorrow; paused alerts suppress banners but the ledger keeps recording. The notification prompt was observed from the installed build on 2026-09-04, which is evidence the bundle and signature are right; the user had not yet clicked Allow at the time the facts were recorded.

**Evidence.** `Sources/App/NotificationService.swift` (header comment and `post`), `Sources/App/AppCoordinator.swift` (`handle(_:engine:)`, `pauseAlerts`), `Sources/App/StatusBar/StatusItemView.swift` (`textIsRed`), `Sources/App/Settings/SettingsView.swift` (`AlertSettings` footnote). Research report, topic 2, verified item 17, gotchas 10, 12 and 13. Critique, "missing" item 15.

---

## ADR-021: Launch at login on by default, reconciled on every launch

**Context.** The user chose launch at login on by default. `SMAppService` records the registration in the background task management database against the bundle it registered. During the build a first-run-only registration read `.notFound` after the next reinstall, because replacing the bundle in `/Applications` left the record pointing at the old copy, and the app quietly stopped launching at login.

**Decision.** `AppSettings.launchAtLoginWanted` stores the user's intent, default `true`, separately from what the system reports. `AppCoordinator.reconcileLaunchAtLogin` runs on every launch when the app is in `/Applications` and re-registers or unregisters so the system state matches the preference. `register()` is idempotent, and `LoginItemManager` treats `kSMErrorAlreadyRegistered` as success. `.requiresApproval` is surfaced as a button that opens System Settings rather than a toggle that appears to do nothing. Registration is skipped outside `/Applications`, where the menu and Settings say the login item is fragile. `scripts/uninstall.sh` runs the bundle with `--unregister-login-item` before deleting it, because the database keys off the bundle.

**Consequences.** Reinstalls no longer lose the login item; this was verified enabled across two reinstalls. A user who turns it off keeps it off, because the preference is consulted first. The app must be code signed for `SMAppService` to work at all (ADR-023).

**Evidence.** `Sources/App/AppCoordinator.swift` (`reconcileLaunchAtLogin` and its comment), `Sources/App/AppSettings.swift` (`launchAtLoginWanted`), `Sources/App/LoginItemManager.swift`, `Sources/App/AppDelegate.swift` (`handleCommandLineFlags`), `scripts/uninstall.sh`. Session fact: bug 6; commit "login re-register fix". Research report, topic 2, gotchas 14 and 15.

---

## ADR-022: Versioned atomic history with additive method metadata

**Decision.** Keep atomic JSON envelope version 1 and the same bundle-keyed storage paths: `speedtests.json` (cap 200) and `outages.json` (cap 500). Add optional `methodologyVersion`, `downloadQuality` and `uploadQuality` to `SpeedTestResult`. Older records decode with nil metadata and remain labelled as earlier Cloudflare measurements; new results use method 2. Apple extras remain separate.

**Consequences.** No destructive history migration is required. Unknown envelope versions or genuinely invalid JSON still move aside to `.bak`. Only a successful current run writes a result; cancellation/interruption preserves the previous result and history.

**Evidence.** `AtomicJSONStore`, `SpeedTestResult`, `SpeedTestController`, legacy decoding/persistence tests and run-gate tests.

---

## ADR-023: Local signing configuration and public build privacy

**Context.** macOS notifications and login registration depend on code identity. A
stable developer signature can preserve permissions across rebuilds, but certificates
also disclose the certificate holder's identity and team. Those details do not belong
in public source or a privacy-preserving development artifact.

**Decision.** Keep personal signing configuration in untracked local overrides. Public
source must build without a contributor's certificate. A distributable Developer ID
release requires explicit signing and notarization by its publisher; passing a local
build is not evidence of either. Historical v1.0/v1.1 local installations used a
personal development certificate, and that original binary must be reviewed before
public distribution. The app target has App Sandbox disabled; hardened runtime is
used with developer signing. This enables the optional Apple subprocess test.

**Consequences.** An ad-hoc build does not identify the developer and may require macOS
permissions to be granted again after replacement. Certificate private keys,
provisioning profiles and credentials must never be committed. Use the certificate's
OU for a local team setting, rather than confusing it with the CN suffix.

**Evidence.** `project.yml`, packaging scripts, the installed-app checks summarized in
[current verification](VERIFICATION-1.1.md), and the signing behavior observed during
the original release. Notification permission persistence and first launch on a
second Mac remain separate verification tasks.

## ADR-024: Deployment target macOS 14

**Context.** The app needs `NSApp.activate()` (macOS 14) to front Settings and About from an accessory app without the deprecated `activateIgnoringOtherApps`, the `@Observable` macro (macOS 14) for its models, `.contentTransition(.numericText())` on the readouts, `SMAppService` (macOS 13), and `OSAllocatedUnfairLock` (macOS 13). The two `LSUIElement` apps already installed on the development machine both ship `LSMinimumSystemVersion = 14.0`. Going to macOS 26 would gain `NWPath.linkQuality` and Liquid Glass but cut off users for no feature this app needs.

**Decision.** `project.yml` sets `MACOSX_DEPLOYMENT_TARGET: "14.0"` and `Support/Info.plist` sets `LSMinimumSystemVersion` to 14.0. No macOS 26-only API is used. `AppCoordinator.openSettings` presents a retained native `SettingsWindowController` hosting the SwiftUI settings view. The panel, context menu and Cmd+, share that window; the removed `showSettingsWindow:` selector no longer opens SwiftUI Settings on current macOS.

**Consequences.** The app runs on macOS 14 and later. The SDK is 26.5 and the host is 26.6.2, so any future use of a symbol gated above 14.0 must be wrapped in `#available`. Deviation: the plan mentioned `.glassEffect` under an availability check for the panel background; the code does not use it.

**Evidence.** `project.yml`, `Support/Info.plist`, `Sources/App/AppCoordinator.swift` (`openSettings`, `showAbout`). Research report, topic 2, verified items 11, 12, 18 and the deployment-target recommendation; topic 3, gotcha 16.

---

## ADR-025: Swift 6 language mode with per-target default actor isolation

**Context.** Swift 6 language mode enforces strict concurrency. UI code wants everything on the main actor; measurement code wants to be nonisolated so actors, lock-guarded delegate classes and pure structs can run off the main thread and be tested without a host app. `SWIFT_DEFAULT_ACTOR_ISOLATION` exists in Xcode 26.6's `Swift.xcspec` and maps `MainActor` to `-default-isolation=MainActor`, but Xcode silently ignores unknown build settings, so the plan required proof that the flag reached the compiler.

**Decision.** `SWIFT_VERSION: "6.0"` for every target. `SpeedCore` (a static library) sets `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`, the app sets `MainActor`, and `SpeedCoreTests` sets `nonisolated`. The test bundle depends only on `SpeedCore` and has no `TEST_HOST`, so `xcodebuild test` never launches the menu bar agent. Isolation crossing happens only through `await` on `SpeedCore` async APIs and `AsyncStream` consumption in `AppCoordinator`. Several app classes carry an explicit `@MainActor` as belt and braces; `AppCoordinator`, `AppDelegate` and `StatusItemView` rely on the target default.

**Consequences.** The flag never appears in the `xcodebuild` log, so the plan's "grep the log" check could not work. It was proven empirically instead: a probe that calls a `@MainActor` function synchronously compiles in the app target and fails in `SpeedCore` with "call to main actor-isolated global function in a synchronous nonisolated context". `ENABLE_USER_SCRIPT_SANDBOXING: YES` blocked the static library's Objective-C header copy phase, so `SpeedCore` sets `SWIFT_INSTALL_OBJC_HEADER: NO` and an empty `SWIFT_OBJC_INTERFACE_HEADER_NAME`. Historical v1.0 test counts are recorded in `VERIFICATION.md`; current outcomes are recorded in `VERIFICATION-1.1.md`.

**Evidence.** `project.yml`, `Sources/App/AppCoordinator.swift`, `Sources/SpeedCore/SpeedTest/Cloudflare/DownloadStream.swift` (`@unchecked Sendable` lock-guarded delegate), `Sources/SpeedCore/Outage/OutageEngine.swift` (actor). Session facts: the isolation proof; bug 4; test counts. Research report, topic 2, verified item 20 and gotcha 19.

---

## ADR-026: Repository inside iCloud Drive, build products outside it

**Context.** A checkout may live inside iCloud Drive and contain spaces. iCloud's file provider tags files with extended attributes (`com.apple.fileprovider.fpfs#P`, `com.apple.FinderInfo`), evicts files, and leaves `.icloud` placeholders. During the build, staging the DMG inside the repository baked those attributes into the image, and `codesign --verify` rejected the installed app with "resource fork, Finder information, or similar detritus not allowed".

**Decision.** DerivedData defaults to `$HOME/Library/Developer/Xcode/DerivedData/InternetSpeedReader` in both scripts (`DD` variable), outside iCloud. The generated `InternetSpeedReader.xcodeproj` is git-ignored and regenerated with `xcodegen generate --spec project.yml`. `.gitignore` also excludes `dist/`, `build/`, `*.icloud`, `*.nosync/` and `._*`. The DMG is staged in `mktemp -d` under `$TMPDIR`, copied with `ditto --noextattr --noqtn`, stripped with `xattr -cr`, and re-signed before imaging. Every path in the scripts is quoted.

**Consequences.** Nothing that Xcode or `hdiutil` produces is synced by iCloud. Anyone building this repository elsewhere should keep the same split. Deviation: the plan staged the DMG in `build/dmg` inside the repository; the code moved staging outside iCloud after the signature failure.

**Evidence.** `scripts/install.sh`, `scripts/make-dmg.sh` (staging comment), `.gitignore`. Session fact: bug 2. Plan, "Build, sign, install" and "Risks and mitigations" (iCloud Drive).

---

## ADR-027: UDZO disk image on APFS, staged outside iCloud, app and image signed

**Context.** v1.0.0 ships as a drag-to-install disk image. `hdiutil` is present on every Mac; `create-dmg` is not installed and is not needed. The image must contain a signed app whose signature still verifies after Finder copies it to `/Applications`, plus a first-launch note because the build is not notarised.

**Decision.** `scripts/make-dmg.sh` regenerates the project, builds Release, copies the app into the temporary staging folder, adds a symbolic link to `/Applications` and a "READ ME FIRST.txt" with the Gatekeeper workaround, strips extended attributes, re-signs with the Apple Development identity using `--options runtime --timestamp=none`, verifies strictly, then runs `hdiutil create -volname "Internet Speed Reader" -srcfolder "$STAGING" -ov -format UDZO -fs APFS`. It verifies the image with `hdiutil verify`, signs the image with the same identity on a best-effort basis, and prints the size and SHA-256. The version comes from `MARKETING_VERSION` in `project.yml`, giving `dist/InternetSpeedReader-<version>.dmg`.

**Consequences.** The image is compressed and read only. The README and the in-image note both tell users on other Macs to right-click Open once or remove the quarantine attribute. Deviation: the plan specified `-fs HFS+`; the script uses APFS. Deviation: the plan's optional Finder window layout with a background image was not done.

**Evidence.** `scripts/make-dmg.sh`, `README.md` ("Install"). Session facts: release PR #1 merged into `main` (merge commit d0ee6db), tag v1.0.0, GitHub release with `InternetSpeedReader-1.0.0.dmg`, 1.5 MB (1,564,806 bytes), SHA-256 `4b11408d3d5d5c8e9d99d45311e8f3eb874048346fe0228d3e9609e353282f46`. Plan, "DMG packaging".

---

## ADR-028: Own cancellation through cleanup and reject stale callbacks

**Decision.** `SpeedTestRunGate` owns a UUID until transport cleanup and lifecycle restoration finish. Stop is a visible busy state. Late/wrong-run progress is rejected, phase progress cannot move backwards, and 30-second monotonic spacing starts at completion. Cloudflare-only rate limiting does not permanently block the Apple alternative.

**Consequences.** The controller saves only successful, current results. Sleep and meaningful native path changes interrupt tests. `measuringCapacity` controls the testing indicator separately from cleanup ownership, and completion requests an independent uncancelled connectivity probe rather than announcing success as online. The Apple runner joins termination/pipe cleanup, escalates after two seconds and rejects malformed, partial, abnormal-exit or cancelled output.

**Evidence.** `SpeedTestController`, `SpeedTestRunGate`, `AppCoordinator`, `NetworkQualityRunner`, injected process/deadline tests and transport cancellation tests. Current verification records actual end-to-end outcomes.

---

## Historical alternatives considered

These summarize the original selection context, not newly verified provider terms or platform guarantees. Current choices are stated in the records above.

| Alternative | Rejected because | What was chosen instead |
|---|---|---|
| SwiftUI `MenuBarExtra` | Label limited to text or text plus image; no programmatic present or dismiss; no right-click; no access to `NSStatusItem` | AppKit `NSStatusItem` with `StatusItemView` (ADR-001) |
| Two-line `NSStatusBarButton.attributedTitle` | Reported to clip and need per-display baseline offsets | Custom `NSView` drawing (ADR-001) |
| Ookla Speedtest CLI | Proprietary, personal command-line use only, 2022 binary, no permitted server API | Cloudflare endpoints (ADR-002) |
| M-Lab NDT7 | Four automated tests a day, public CC0 publication, GDPR policy requirement | Cloudflare endpoints (ADR-002) |
| Fast.com | Token scraped from a content-hashed bundle that rotates on deploy | Cloudflare endpoints (ADR-002) |
| LibreSpeed | No maintained public server pool; LGPL-3.0 backend | Cloudflare endpoints (ADR-002) |
| Apple `networkQuality` as the primary engine | About 26 s per run, Apple CDN only, no ISP or jitter, no progress | Optional "Apple Deep Test" (ADR-002) |
| `getifaddrs` byte counters | 32-bit, already wrapped once on the development machine | `NET_RT_IFLIST2` and `if_data64` (ADR-003) |
| Summing all interfaces | Counts `awdl0`, `lo0` and VPN double-counting | One selected interface (ADR-004) |
| One shared `URLSession` for all streams | Six-connection default and HTTP/2 coalescing collapse the streams | One session per stream (ADR-005) |
| `URLSession.data(for:delegate:)` for downloads | Never calls `didReceive data` on a task delegate; counted 0 bytes | Session-level delegate (ADR-006) |
| Percentile or average of per-request rates | Under-reports by roughly the stream count | Confirmed payload on one timeline (ADR-007) |
| Chunk size divided by stream count | Requests finish too fast; fast links read low | Per-stream sizing, two seconds per request (ADR-008) |
| Raw time-to-first-byte as ping | Inflated by worker cold starts, 213 to 793 ms in research | Subtract `Server-Timing` (ADR-010) |
| Subtracting server time from throughput | Throughput is bytes over a timeline, not per-request duration | Latency only (ADR-010) |
| `cfL4` `lost` and `retrans` as packet loss | Zero on healthy and mildly lossy links alike | Not shown |
| Accepting any 200 as download bytes | A captive portal's HTML would be measured as speed | Hard abort on validation failure (ADR-011) |
| In-memory `Data` upload bodies | Whole body held in RAM | File-backed fixtures (ADR-012) |
| Custom `InputStream` upload body | More code and bug surface than v1 needed | Session-level file-backed upload delegate (ADR-012) |
| Reconciling the live meter to the speed test | They measure different layers | Separate, labelled numbers (ADR-013) |
| Counters as an "internet is up" signal | LAN traffic flows during WAN outages | Active HTTP probe (ADR-014, ADR-016) |
| Trusting a satisfied `NWPath` | A captive portal satisfies the path | Probe on every satisfied path (ADR-014) |
| ICMP ping (raw or `SOCK_DGRAM`) | Unverified end to end; different path from the servers users compare against | HTTP probes and HTTP latency (ADR-016, ADR-010) |
| Probing the default gateway | Local-network traffic, triggers the privacy prompt | Off-subnet endpoints only (ADR-016) |
| `Date` for elapsed time | Moves on NTP correction | `ContinuousClock` via `TimeSource` (ADR-017) |
| Dividing by the nominal tick interval | Coalesced timers land late and over-report | Measured elapsed time (ADR-017) |
| Showing the larger of download and upload each tick | Flips several times a second on mixed traffic | Sustained upload activity and hysteresis (ADR-018) |
| Banker's rounding in the bar | 84.25 read as "84.2" | Half-up rounding (ADR-019) |
| `.timeSensitive` or `.criticalAlert` notifications | Require Apple-granted entitlements | `.active`, alert only, no sound (ADR-020) |
| Registering the login item once on first run | `.notFound` after the next reinstall | Reconcile every launch against a preference (ADR-021) |
| SwiftData or `UserDefaults` for history | `ModelContext` is not `Sendable`; defaults grow unbounded | Versioned atomic JSON (ADR-022) |
| Ad-hoc code signing | `cdhash` changes every rebuild and drops grants | Apple Development identity (ADR-023) |
| App Sandbox on | No benefit for a local utility; contested `Process()` behaviour | Sandbox off, no entitlements (ADR-023) |
| Developer ID plus notarisation | No Developer ID certificate on this machine | Deferred past v1 (ADR-023) |
| Hardened runtime off | Forecloses notarisation later | Hardened runtime on (ADR-023) |
| Deployment target macOS 26 | Cuts off users for APIs this app does not need | macOS 14 (ADR-024) |
| Grepping the build log for `-default-isolation` | The flag never appears in the log | Empirical compile probe (ADR-025) |
| A test bundle hosted by the app | Would launch the agent on every test run | Library-only test bundle (ADR-025) |
| DerivedData or DMG staging inside iCloud Drive | iCloud extended attributes broke the signature | Outside iCloud (ADR-026, ADR-027) |
| `-fs HFS+` disk image | Not needed on macOS 14 and later | APFS (ADR-027) |
| Scheduled tests, global hotkey, auto-update | Out of scope for v1 by user decision | On-demand tests only |

## Historical-plan differences still relevant

| Plan said | Code does | Record |
|---|---|---|
| Confusing certificate identifier with team ID | Supply the certificate OU as the local team override | ADR-023 |
| Verify the isolation flag by grepping the build log | Proven by a compile probe; the flag never appears in the log | ADR-025 |
| No mention of `ENABLE_USER_SCRIPT_SANDBOXING` | Set to YES, with `SWIFT_INSTALL_OBJC_HEADER: NO` on `SpeedCore` | ADR-025 |
| Stage the DMG in `build/dmg`, `-fs HFS+` | Stage in `mktemp -d` outside iCloud, `-fs APFS`, `ditto --noextattr`, `xattr -cr`, re-sign | ADR-026, ADR-027 |
| ISP fallback chain: `/meta`, `__down` headers, Apple `nq`, "Unknown ISP" | `/meta` then "Unknown ISP" | ADR-002 |
| Loaded latency sampled during throughput phases | Fields exist in `SpeedTestResult`; never populated | ADR-002 |
| 15 min, 1 h, 6 h backoff on 403 or 429 | Single 15 minute block for HTTP 429; HTTP 403 is an explicit refusal | ADR-002 |
| One halving retry on a byte-cap 403 | One-byte HTTP 403 retains the legacy `.byteCapExceeded` name; cause unknown, surfaced as HTTP 403, not retried or mislabeled as a rate limit | ADR-008 |
| Two-line layout as the default | Adaptive single number as the default | ADR-018 |
| Login item registered on demand | Reconciled against `launchAtLoginWanted` (default true) on every launch | ADR-021 |
| Liquid Glass panel background under `#available(macOS 26)` | Not used | ADR-024 |
| Real VPN connect and disconnect exercised in M3 | Not recorded in the session facts; covered by unit tests only | ADR-004 |
