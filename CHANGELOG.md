# Changelog

## 1.1.0

### Automatic monitoring

- Keep live readings active independently of the panel, with a one-second default
  cadence and an optional policy for battery and Low Power Mode.
- Fix delayed five-second readings being rejected as stale. Calculate rates from
  actual elapsed time and use cadence-aware freshness checks.
- Reset counters, smoothing, freshness and direction together after interruption;
  recover when counters return and distinguish unavailable data from measured idle.
- Give sustained upload activity priority while allowing for small control packets.
  Keep download as the default direction, including when idle.
- Prefer interfaces supported by the active network path and retain protection
  against counting physical and VPN traffic twice.
- Expose login-item registration errors and provide a working native Settings window.

### Manual speed tests

- Validate completed downloads and server-confirmed uploads before counting their
  bytes in final results. Keep provisional progress separate from validated results.
- Share phase deadlines and byte budgets across streams, adapt request sizes from
  per-stream performance, and bound the completion period for outstanding requests.
- Calculate headline throughput after warm-up using measured time, including stalls.
  Remove the rule that discarded the slowest 30% of readings.
- Add per-direction measurement quality and method metadata while preserving old
  history. Label previous results with their time, engine and earlier method.
- Report HTTP 403 refusals as failures; reserve rate-limit cooldowns for HTTP 429.
  Update cooldown countdowns automatically.
- Isolate each run’s callbacks, cancel on sleep or network changes, and wait for
  cleanup before allowing another run.
- Validate Apple Deep Test process exit status and output, and handle cancellation,
  deadlines and pipe draining.

### Verification

- Expand the core suite from 75 to 125 passing tests, including delayed sampling,
  counter recovery, direction changes, transport failures, cancellation and legacy data.
- Record independent interface-counter comparisons and Apple reference tests in the
  [verification report](docs/VERIFICATION-1.1.md).
- Cloudflare returned HTTP 403 during live verification. Successful sequential
  Cloudflare comparisons remain outstanding; no agreement with Ookla is claimed.

## 1.0.0 — 2026-09-04

- Initial native macOS menu bar app with live interface throughput, outage detection,
  silent notifications, launch at login and local history.
- Add manual Cloudflare tests and an Apple `networkQuality` second opinion.
- Establish the UI-free `SpeedCore` library and its original 75-test suite.
