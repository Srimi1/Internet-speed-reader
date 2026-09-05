# Version 2.0.0 verification

What was actually checked, and what is still outstanding. Passing tests and a local
install do not establish every real-world behaviour, so the gaps are listed as gaps.

## Automated

| Check | Result |
|---|---|
| Library suite before any change | 125 tests in 23 suites passed |
| Library suite at 2.0.0 | 187 tests in 31 suites passed |
| Release build of the app target | Succeeded |
| Install, signature verification and launch | Succeeded |

New coverage: formatter precision per unit and band boundaries, layout default and
migration, readout hold and the single-fire recovery latch, activity detection including a
ten-minute idle stream and a post-transfer chatter stream, path-change classification,
per-engine backoffs, the chain's fallback and stop rules, endpoint headers, and the
ladder's avoidance of the refused range. Tests link only the library, use no network and
never launch the app.

## The reported symptom

The complaint was that the app was "not active": the menu bar read `0.0`. It was sampling
every second the whole time. With megabytes per second selected, the old formatter printed
`0.0` for everything below 0.4 Mbps, and the single-number layout hid one direction
entirely.

Measured on the installed 2.0.0 build:

| Observation | Value |
|---|---|
| Preferences after upgrade | `barLayout` written as `twoLine`, unit preference preserved |
| Status item width, two rows, megabytes per second | 58 points |
| Sampling cadence | ~1.05 s, unchanged |
| Idle sample seen in the log | 0.0155 Mbps down, which now renders `<0.01` rather than `0.0` |
| Transfer sample seen in the log | 4.96 Mbps down, which renders `0.62` rather than `0.6` |
| Download activity detection | Fired on the 4.96 Mbps sample, released afterwards |
| Existing data | History and outage ledger loaded; no `.bak` file created |

The two-row layout is narrower than the single-number layout it replaces, so it does not
make a crowded menu bar worse.

## The capacity test

Version 1.1 received HTTP 403 twice on the day of the report. The cause was reproduced
from the same machine and network:

| Request | Result |
|---|---|
| Legacy host, 16,777,216 bytes, no browser headers | HTTP 403, one-byte body |
| Legacy host, same size, with `Referer` and `Origin` | HTTP 200, exactly 16,777,216 bytes |
| Preferred host, same size, no headers | HTTP 200, exactly 16,777,216 bytes, HTTP/2 |
| Preferred host, metadata | HTTP 200 |
| Preferred host, 4 MiB upload | HTTP 200, `cf-meta-upload-bytes` exactly 4,194,304 |

The ladder's power-of-two rung at 16,777,216 bytes sits inside the range the legacy host
refuses, which is why some runs failed while their neighbours succeeded. Version 2.0 sends
the headers on every request, prefers the host with no gate, and steps the ladder around
the range on the legacy host.

## Outstanding

- A full GO run through the installed application has not been completed in this session;
  the endpoints were verified directly instead. Three consecutive runs, and a forced
  fallback showing each engine's label, remain to be recorded.
- A photograph of the menu bar was not captured: screen capture was unavailable on the
  machine at the time. The rendered strings are covered by tests and the underlying values
  by the log, but the pixels were not photographed.
- Sleep and wake, a real VPN, launch at login in a fresh session, and a rollback rehearsal
  to 1.1.0 have not been re-checked on 2.0.0.
- Activity thresholds are reasoned from this machine's traffic rather than fitted to a
  capture of the user's own tools.
- The macOS menu bar permission introduced in recent versions cannot be read by an app.
  If the item is ever missing, System Settings is the only place to confirm it.
