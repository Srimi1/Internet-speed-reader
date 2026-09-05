# Changelog

## 2.0.0

### The menu bar

- Show download and upload together by default, with the transferring direction in bold.
  The single-number layout remains selectable; a stored preference for it is migrated once.
- Scale precision to the magnitude of the value in the unit being shown, so small but real
  traffic reads as `0.02` or `<0.01` rather than `0.0`. Only a measured zero shows `0.00`;
  an unavailable reading still shows a dash. Menu bar strings stay within five characters.
- Format the panel in the same unit as the menu bar, and stop converting values that are
  not speeds, such as latency and Apple's responsiveness figure.
- Put the current speeds and the last test in the tooltip, and reassign it only when it
  changes.

### Live monitoring

- Hold the last reading, dimmed, through a brief gap instead of blanking the display, and
  request a fresh baseline once per gap rather than on every refresh.
- Classify path changes: only a change of the measured interface rebinds the meter, so
  AirDrop, a DHCP renewal or a roam no longer blanks the readout or clears the graph. Any
  path change still ends a running capacity test.
- Detect transfer activity per direction on a byte window, using a matching allowance for
  received packets so a large upload's acknowledgements do not mark the download active.

### Capacity tests

- Try Cloudflare's measurement host, then the classic host, then Apple's tool, and record
  which one produced the result and what it fell back from.
- Send the browser headers on every request. Their absence is why the classic host refused
  download sizes between 11,000,000 and 19,999,999 bytes, which is exactly where the
  request ladder's 16 MiB rung fell. The ladder now also steps around that range.
- Report a server refusal as a refusal rather than an engine fault, and back off that
  engine alone: five minutes for a refusal, fifteen for a rate limit. Backoffs are recorded
  even when every engine refuses.
- Stop the chain rather than paying for another full transfer once a download phase has
  completed or 64 MB has moved.
- Reopen the panel when a test finishes while it is closed, and act on the outage banner's
  buttons.

### Verification

- 187 library tests in 31 suites, up from 125.
- The refusal, the header fix and the preferred host were reproduced against the live
  endpoints; see the [verification report](docs/v2/VERIFICATION-2.0.md) for what remains
  unchecked.

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
