# Architecture

This describes the v1.1.0 implementation. The source is authoritative; historical plans
and the v1.0 measurements describe earlier behavior. Build, test and installed-app
acceptance evidence belongs in [VERIFICATION-1.1.md](VERIFICATION-1.1.md), not in this
architecture description. [DECISIONS.md](DECISIONS.md) records the reasoning.

The panel, native context menu and Cmd+, open one retained `SettingsWindowController` hosting `SettingsView`. This replaces the obsolete `showSettingsWindow:` selector. HTTP 403 refusals remain explicit server errors; only HTTP 429 activates the rate-limit backoff. Rejected requests log phase, endpoint path, status, requested size and bounded diagnostic headers, without client metadata or response bodies.

## Targets and ownership

`project.yml` is the only project definition. Regenerate with XcodeGen after changing
it or adding source files; the Xcode project is ignored. It also generates
`Support/Info.plist`, so edit plist properties in the YAML.

| Target | Responsibility | Isolation |
|---|---|---|
| `SpeedCore` | Counters, path snapshots, measurement engines, outage logic, storage and pure policies | Nonisolated Swift 6; mutable I/O belongs to actors or lock-protected Sendable types |
| `InternetSpeedReader` | AppKit status item, SwiftUI panel/settings, lifecycle, notifications and login item | MainActor |
| `SpeedCoreTests` | Pure logic and injected counter/clock/transport/process tests | Nonisolated; links only SpeedCore, with no `TEST_HOST` or app launch |

The deployment target is macOS 14. The app is an `LSUIElement` agent with no Dock icon,
App Sandbox disabled and hardened runtime enabled. Its stable bundle identifier is
`com.srimi.internetspeedreader`. The build configuration is 1.1.0/build 2, signed with
a locally configured identity when supplied; this is not a claim
that a release has been published or notarised.

## Continuous live monitoring

`AppDelegate` creates `StatusItemController` and calls the idempotent
`AppCoordinator.start()`. Sampling, path observation and outage detection begin at
launch, independently of the panel and GO. The coordinator retains the App Nap
activity with `.userInitiatedAllowingIdleSystemSleep`; normal system sleep is allowed.

1. `NWPathSource` converts path callbacks into Sendable `PathSnapshot` values. The
   selector deduplicates indices and excludes loopback/Apple peer-to-peer interfaces.
   It prefers a physical interface whose type is used by the path, then another
   physical interface, then a tunnel. Same-type ties retain path order. This is
   type-level evidence, not exact route attribution. Physical and tunnel bytes are
   never summed.
2. `SysctlCounterReader` reads `NET_RT_IFLIST2` and `RouteMessageParser` extracts 64-bit
   receive bytes, transmit bytes and transmitted packets from `if_data64`.
3. `LiveThroughputMonitor` samples on an injected `TimeSource`. `ThroughputCalculator`
   divides deltas by measured elapsed seconds; intervals below 0.2 seconds wait for
   more data. Counter decreases, rates above 50 Gbps, and gaps exceeding
   `max(5, 3 × expectedIntervalSeconds)` discard the reading and rebaseline.
4. `updates()` emits either a `ThroughputSample` or an unavailable reason: starting,
   no interface, missing counters, paused or stale. Streams have bounded buffers.
   Missing counters invalidate the old baseline and recover without a click. Start
   is idempotent, and cancellation of an old loop cannot clear its replacement.
5. The coordinator observes updates and publishes the UI state. Unavailable readings
   show `—`; a real idle sample shows near-zero download. The independent status-item
   refresh loop also checks freshness, updates countdowns and expires paused alerts.

`LiveRefreshPolicy` defaults to one-second sampling on every power source. Missing,
unknown and legacy `onlyWhenOpen` preferences migrate to `always`; an explicit
`reduceOnBattery` choice is retained. That option uses 1/2/5 seconds for AC/battery/Low
Power Mode. `PowerPolicyObserver` observes both IOKit power-source changes and
`NSProcessInfoPowerStateDidChange`; settings changes also update cadence immediately.

### Direction and smoothing

`ThroughputSample.uploadActivityMbps` estimates meaningful upload activity as
`max(0, transmittedBytes − 160 × transmittedPackets) × 8 / elapsed / 1e6`.
This allowance is used only to classify direction. Displayed upload Mbps always comes
from the unadjusted byte rate.

`ActiveDirectionSelector` enters upload after activity is at least 0.15 Mbps for
2 seconds, regardless of how large the download is. It returns to download after
activity stays below 0.075 Mbps for 3 seconds. Both raw directions below 0.15 Mbps
return immediately to the resting download state. Network/sleep lifecycle changes
clear the selector's history.

This is a conservative heuristic, not packet inspection. Many acknowledgement packets
can hide a small simultaneous upload; VPN/QUIC and offload behavior can also affect
classification. The panel always exposes both measured directions.

`ThroughputSmoother` uses a one-second half-life based on measured elapsed time. First
samples after reset are shown directly, and rates below 0.15 Mbps use their actual raw
value so a completed transfer does not linger as a large idle reading.

## Capacity tests and run ownership

A left click opens the existing panel and forces a connectivity check. GO starts a
Cloudflare test; Apple Deep Test is a separate engine. Both live directions and the
last test's timestamp/provider remain distinct. Closing the popover does not stop a
test, and it does not schedule future tests.

`SpeedTestController` owns each run through transport cleanup using the pure
`SpeedTestRunGate`. Stop enters a stopping state until the engine and lifecycle cleanup
return. Progress must match the active run ID and cannot move the phase backwards.
Cancelled/interrupted runs do not enter history or replace the previous result.
Cooldown uses monotonic time: 30 seconds after a run finishes, with an additional
15-minute Cloudflare-only block for rate limiting. Apple remains an alternative after
the shared spacing expires.

The coordinator disables new tests without a satisfied path, during sleep or a captive
portal, and while the gate is busy. `NWPathSource` suppresses native `NWPath` equality
matches and increments generation only when that native path changes. The coordinator
compares this generation alongside status, interfaces and cost/constraint flags, so a
route change on the same adapter still interrupts a test while duplicate callbacks do
not. Meaningful changes or sleep also reset live display state. `measuringCapacity`
controls the testing indicator separately from the gate's cleanup-busy state.
Completion resumes an independently scheduled, uncancelled connectivity probe; it does
not manufacture an online state from a speed-test result.

### Cloudflare methodology 2

`CloudflareSpeedTest` accepts injected time and transport for tests. Production uses
`URLSessionCloudflareTransport`, with one ephemeral session per stream, no cache,
identity encoding, request/resource deadlines and unique request nonces. Defaults
remain six download streams for 10 seconds and four upload streams for 8 seconds;
data saver shortens those phases and lowers their byte ceilings.

- Small initial probes and fixture rungs support slow links; upload fixtures are
  prepared serially before phase measurement. Each phase has one start time, an
  admission cutoff, a shared `PhaseByteBudget` and a 2-second bounded drain for requests
  already admitted. Reservations include
  in-flight requests and the initial probes, preventing concurrent cap overshoot.
- `DownloadStream` is the session-level delegate for downloads and file-backed
  uploads. Downloads require valid response metadata and exact actual body length.
  Uploads require the matching server-confirmed count and matching client progress.
  Cancellation waits for task completion; malformed, failed and unconfirmed requests
  cannot become successful payload.
- `ByteLedger` supplies provisional gauge progress. Each request separately retains
  its byte callback times in `RequestPayloadTimeline`. Only a validated request is
  committed to `ConfirmedPayloadLedger`, preserving those original times rather
  than placing its bytes at acknowledgement time.
- The headline is confirmed payload over measured post-warm-up elapsed time. The first
  1.5 seconds are excluded; zero-rate intervals, stalls, the partial final interval
  and acknowledgement drain remain. No low/high percentile trimming is applied.
  The full-phase mean and a one-second-window peak statistic are stored separately.
- At least one second of usable positive measurement is required. Per-direction
  quality is `good`, `shortSample` (under 3 seconds), `dataLimited`, `variable`
  (coefficient of variation above 0.25 on one-second windows), or `incomplete` when
  unfinished transfers are excluded. Insufficient validated data produces an error.

Latency uses HTTP samples with `Server-Timing` subtracted; server-measured TCP RTT is
kept separately. ISP/server metadata comes from Cloudflare `/meta` when available.
Providers use different servers and methods: none of these values promises equality
with Ookla. Interface counters and capacity results have no fixed overhead conversion.

### Apple engine

`NetworkQualityRunner` uses an injectable `NetworkQualityProcess`; production wraps
`/usr/bin/networkQuality -c -s -M <seconds>` with optional `-I <interface>`. The Settings
runtime is passed through. The hard deadline is requested duration plus 10 seconds;
termination escalates after 2 seconds and waits for exit and pipe cleanup. Nonzero or
abnormal exit, truncated/malformed/error JSON, invalid throughput and cancellation
cannot produce a successful result. Responsiveness and base RTT stay in `AppleExtras`.

## Outages, persistence and compatibility

`OutageEngine` drives the pure `ConnectivityStateMachine`, an HTTP prober and
`OutageLedger`. A satisfied path is not proof of internet access: gstatic is probed
with Apple's captive endpoint as fallback, under a shared 3-second budget. Two failures
confirm an outage; one successful probe restores service. Path loss has a 3-second
debounce. Grace periods suppress banners, and sleep closes an open outage and pauses
the engine. Capacity tests temporarily suspend outage probing.

`NotificationService` posts silent active-level banners; Focus and permission settings
can suppress them. Pause-alert expiry is checked by the background UI refresh loop.
Launch at login defaults on and is reconciled with `SMAppService` on every launch from
`/Applications`, while respecting an explicit off preference or required system approval.

| Store | Location / behavior |
|---|---|
| Speed history | `~/Library/Application Support/com.srimi.internetspeedreader/speedtests.json`, cap 200 |
| Outage ledger | Same directory, `outages.json`, cap 500 |
| Preferences | UserDefaults domain `com.srimi.internetspeedreader` |
| Upload fixtures | `~/Library/Caches/com.srimi.internetspeedreader/upload/`, file-backed random bodies |

JSON stores retain envelope version 1, atomic writes and ISO 8601 timestamps. Unknown
versions or decode failures are moved aside to `.bak`. `SpeedTestResult` adds optional
`methodologyVersion`, `downloadQuality` and `uploadQuality`; old records decode with
these fields nil, and earlier Cloudflare measurements are labelled in the panel.
Method 2 records confirmed byte totals and per-direction quality. Apple result extras
remain separate. No destructive history migration or bundle-identifier change is needed.

## Remaining limitations

- Loaded latency fields exist but are not populated. There is no scheduled capacity
  testing, packet capture, exact app-level upload attribution or auto-update service.
- The settings for notify-on-drop/restore and outage-duration thresholds remain
  unwired; the engine still uses its defaults. Do not claim these controls work.
- Metered-test confirmation and automatic panel reopening preferences remain unwired.
  Notification action callbacks for Run Speed Test/Show Outage Log are still unassigned.
- Signing remains Apple Development without notarisation. Current installation,
  login/reinstall, power/sleep, VPN and comparison evidence must be checked in
  [VERIFICATION-1.1.md](VERIFICATION-1.1.md).

## Build and maintenance

Keep DerivedData outside the iCloud checkout at
`~/Library/Developer/Xcode/DerivedData/InternetSpeedReader` and quote paths. The scheme
runs the library-only unit bundle. `scripts/install.sh` regenerates/builds, replaces the
installed bundle, verifies its signature and launches it; `scripts/make-dmg.sh` stages
outside iCloud, strips problematic xattrs, signs and verifies before packaging.

The installed bundle supports `--login-status`, `--register-login-item` and
`--unregister-login-item`. Run the application as an installed `.app`; notification APIs
require a bundle. Historical v1.0 verification and build measurements remain in
[VERIFICATION.md](VERIFICATION.md); historical plans are background, not executable
instructions or current acceptance evidence.
