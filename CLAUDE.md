# CLAUDE.md

Read this first. This is the operational map for Internet Speed Reader v2.0.0.
[docs/v2/ARCHITECTURE-2.0.md](docs/v2/ARCHITECTURE-2.0.md) describes what 2.0 changed and
[docs/v2/DECISIONS-2.0.md](docs/v2/DECISIONS-2.0.md) explains why; the 1.x documents still
describe the unchanged measurement spine. Current validation belongs in
[docs/v2/VERIFICATION-2.0.md](docs/v2/VERIFICATION-2.0.md). Earlier verification reports,
research and plans are historical evidence, not current acceptance results.

## What this is

A Swift 6 macOS 14+ menu bar agent using AppKit and SwiftUI. It continuously reads
64-bit kernel interface counters while awake, detects outages with HTTP probes,
posts silent banners and runs on-demand capacity tests against Cloudflare or Apple's
`networkQuality`. Live throughput is actual activity, near zero when idle; GO measures
capacity by transferring data. An unavailable reading is `—`, not zero or an old rate.

The bar shows both directions by default and emphasises the one transferring; the adaptive
single-number layout remains selectable and keeps its own direction selector. Default
cadence is one second, independent of opening the panel. Launch at login remains on by
default. The bundle identifier `com.srimi.internetspeedreader` never changes: defaults,
notifications, stores and login registration depend on it. `project.yml` specifies
2.0.0/build 3; publication/installation status must be verified.

## Commands

Quote checkout paths and keep build products outside cloud-synced directories.
A suggested DerivedData location is `~/Library/Developer/Xcode/DerivedData/InternetSpeedReader`.

| Task | Command |
|---|---|
| Regenerate after project changes or new source files | `xcodegen generate --spec project.yml` |
| Release build | `xcodebuild -project InternetSpeedReader.xcodeproj -scheme InternetSpeedReader -configuration Release -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/InternetSpeedReader" build` |
| Unit tests, no network or test host | `xcodebuild -project InternetSpeedReader.xcodeproj -scheme InternetSpeedReader -destination 'platform=macOS' -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/InternetSpeedReader" test` |
| Build, replace installed bundle, verify and launch | `./scripts/install.sh` |
| Build DMG | `./scripts/make-dmg.sh` |
| Remove app, data, preferences and login item | `./scripts/uninstall.sh` |
| Read installed login status | `/Applications/InternetSpeedReader.app/Contents/MacOS/InternetSpeedReader --login-status` |

Only `SpeedCoreTests` belongs to the scheme's test action. Tests must never launch the
menu bar agent. Run the real application as an installed `.app`, not `swift run` or a
bare executable: notification APIs require bundle context.

## Layout and contracts

| Location | Responsibility |
|---|---|
| `project.yml` | Sole XcodeGen definition; app MainActor, SpeedCore/tests nonisolated. Edit Info.plist properties here. |
| `Sources/SpeedCore/Counters/` | 64-bit byte/packet parser, cadence-aware calculator, availability updates, smoothing and upload direction heuristic. |
| `Sources/SpeedCore/Path/` | Native path change detection, Sendable snapshots, deduplicated physical/tunnel selection. |
| `Sources/SpeedCore/Outage/`, `Probe/` | Pure connectivity state machine, actor engine/ledger, deadline-bound HTTP prober. |
| `Sources/SpeedCore/SpeedTest/Cloudflare/` | Transport/delegate, provisional and confirmed payload ledgers, byte reservations, methodology-2 aggregation and response validation. |
| `Sources/SpeedCore/Apple/` | Injectable process runner, bounded cancellation/exit cleanup, validated Apple JSON. |
| `Sources/SpeedCore/Support/` | Injected time, deadlines, `LiveRefreshPolicy`, `BarLayout`, `SpeedTestRunGate`, formatters, atomic JSON, logging. |
| `Sources/SpeedCore/SpeedTest/Chain/` | Engine protocol and keys, chain policy and runner, Cloudflare and Apple adapters. |
| `Sources/App/` | Composition/lifecycle, status item, panel/settings, power observation, test ownership, notifications and login item. |

## Rules that must hold

- SpeedCore is UI-free. AppKit/SwiftUI/UserNotifications/ServiceManagement belong to
  the MainActor app target. Tests link only SpeedCore and use local doubles.
- Every elapsed-time rule uses injected `TimeSource` or measured monotonic instants.
  `Date` is only for human timestamps. Every network call has a deadline.
- Live rates divide counter deltas by actual elapsed time. Stale gaps exceed
  `max(5, 3 × expectedIntervalSeconds)`; never restore the old fixed five-second limit.
- Menu bar and panel strings scale precision to the magnitude of the value in the unit
  being shown. Never print a bare `0.0` for traffic that is moving: below the displayed
  resolution the string is `<0.01`, a measured zero is `0.00`, and only a missing reading
  is an em dash. Bar strings stay within five characters.
- `LiveReadoutModel` holds the last reading through a transient gap and requests a fresh
  baseline at most once per gap. The refresh loop runs faster than the sampling cadence, so
  an unlatched request would drop the baseline before a delta could be measured.
  A normal five-second Low Power Mode sleep lands slightly late and formerly caused
  every sample to be discarded. Missing counters clear the baseline and publish
  unavailable state. Sleep, wake and a change of the measured interface reset
  smoothing and direction; route-only path changes must not, because `NWPath` yields a new
  snapshot for DNS, gateway and address changes that leave the interface untouched. Any
  path change still ends a running capacity test.
- `LiveThroughputMonitor.updates()` distinguishes samples from unavailable reasons.
  It must run without the popover, recover when counters return, and retain one
  sampling loop across cadence changes. UI refresh independently checks freshness.
- `LiveRefreshPolicy` defaults to `always` (1 second). Missing/unknown/legacy
  `onlyWhenOpen` values migrate to it; explicit `reduceOnBattery` remains 1/2/5 seconds
  on AC/battery/Low Power Mode. `PowerPolicyObserver` and preference changes update it.
- Upload classification uses bytes beyond a 160-byte-per-transmitted-packet allowance:
  entry at 0.15 Mbps for 2 seconds, exit below 0.075 for 3 seconds, idle immediately
  restores download. This is a conservative heuristic with ACK/VPN/QUIC limitations,
  not precise application attribution. Never subtract the allowance from shown Mbps.
- Test progress is provisional. Methodology 2 commits only completed, validated
  requests at their original callback times. Small initial probes support slow links;
  upload fixtures are prepared serially before phase measurement. A shared byte
  budget includes probes and in-flight requests. Stop admitting requests at the phase cutoff, allow a
  bounded 2-second drain, and exclude unfinished transfers from the final payload.
- Headline test throughput uses measured post-1.5-second-warm-up time, including
  stalls and the final partial interval. No percentile trimming. Keep per-direction
  quality and the full-phase mean/peak separately; insufficient data is an error.
- Downloads require valid metadata and an exact actual body length. Uploads require
  the matching `cf-meta-upload-bytes` value and matching client progress. Cancellation
  or partial data must never become a successful saved result.
- A run remains owned through cleanup. `SpeedTestRunGate` rejects old progress,
  overlapping starts and early restart after Stop. Spacing is 30 seconds after finish, and
  backoffs are per engine: five minutes for a refusal, fifteen for a rate limit. The chain
  skips a blocked engine rather than retrying it, and backoffs are applied whether the
  chain succeeded or gave up. Countdown time is monotonic.
- Every Cloudflare request carries `Referer` and `Origin`; the classic host refuses
  download sizes in 11,000,000...19,999,999 without them, and the ladder steps around that
  range on that host. Prefer `h3.speed.cloudflare.com`. Only an explicit refusal, rate
  limit or interception advances the chain; a completed download phase, 64 MB transferred,
  a timeout or a local fault stops it.
- `SpeedTestEngineID` keeps exactly two cases and every new `SpeedTestResult` field is
  optional. The history store moves a file it cannot decode aside, so a new case would
  destroy history on rollback. Engine identity lives in `engineKey`/`endpointHost`.
- Native `NWPath` equality suppresses duplicate callbacks; a changed native path
  advances generation, including changes on one adapter. The coordinator interrupts
  tests on meaningful path changes/sleep and resumes a separate connectivity probe.
  The testing indicator (`measuringCapacity`) is distinct from cleanup ownership.
- History envelope version stays 1. New `methodologyVersion`, `downloadQuality` and
  `uploadQuality` fields are optional so older results load and retain their labels.

## Build and runtime traps

- `URLSession.data(for:delegate:)` did not deliver download chunks to a task-scoped
  delegate. `DownloadStream` uses a session-level delegate; keep that ownership.
- Cloudflare `/meta` needs the request's Referer/Origin headers. `__up` needs a real
  body; a successful empty POST is not evidence of upload capacity. Requests above
  the download byte cap are rejected, so keep chunk sizing bounded.
- App Nap can throttle any timer API. Retain `beginActivity` with
  `.userInitiatedAllowingIdleSystemSleep` and the plist backup; do not prevent normal
  Mac sleep. Timers still need measured elapsed time and cadence-aware staleness.
- `/usr/bin/networkQuality` is camelCase. Its `-M` limit is soft; the runner enforces
  a hard deadline and joins termination/pipe cleanup before allowing another run.
- Use `--info`/`--debug` when inspecting unified logs. Subsystem:
  `com.srimi.internetspeedreader`; categories: `live`, `outage`, `speedtest`, `app`.
- Keep personal signing identities and team IDs in local build overrides, never in
  the repository. `DEVELOPMENT_TEAM` comes from the certificate OU, not its CN suffix.
  Keep `SWIFT_INSTALL_OBJC_HEADER: NO` on SpeedCore to avoid the sandboxed copy failure.
- Stage DMGs outside iCloud with `ditto --noextattr --noqtn`, strip xattrs, re-sign
  and verify. iCloud metadata previously broke strict signature verification.
- Reconcile login registration on every launch from `/Applications`; replacing an
  installed bundle can invalidate the recorded path. Preserve explicit user opt-out.

## Known boundaries

No automatic capacity tests, exact packet/application attribution, loaded latency,
notarisation, global hotkey or auto-update is implemented. Test methods/providers
need not agree with Ookla, and link throughput has no fixed percentage conversion
to payload throughput.

Some older controls remain unwired: notify-on-drop/restore and outage-duration
preferences, metered-test confirmation, automatic panel reopening and notification
action callbacks. The refresh preference, Apple runtime and alert-pause expiry are
wired. Do not infer behavior from the existence of a Settings control alone.

## Release procedure

1. Update version/build in `project.yml`, regenerate and run the library-only tests.
2. Follow [docs/VERIFICATION-1.1.md](docs/VERIFICATION-1.1.md) for installed-app checks:
   closed-panel monitoring, idle/download/upload, sleep/wake, reconnect, power changes,
   GO/Stop and login registration. Record actual outcomes and remaining gaps.
3. Use `scripts/install.sh` and `scripts/make-dmg.sh` for the appropriate authorized
   rollout. Verify signature/image and record SHA-256; `dist/` is ignored.
4. Publish a version/tag/release only when requested; a local version bump or passing
   build is not evidence of a published or installed release.

Version 1.0.0 shipped on 2026-09-04 at `d0ee6db`/`v1.0.0`. Its measurements and
verification gaps remain in `docs/VERIFICATION.md`. Historical plans do not override current code.
