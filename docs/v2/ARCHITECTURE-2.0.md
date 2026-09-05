# Architecture, version 2.0

This describes what changed in 2.0.0 and why. [The 1.1 architecture](../ARCHITECTURE.md)
still describes the measurement spine, which is unchanged. The source is authoritative.

Version 2.0 answers one complaint: the app was running and measuring correctly, but the
menu bar showed `0.0`, one direction was hidden, and the capacity test failed against its
only provider. Nothing in the sampler was wrong; the display and the provider were.

## What the menu bar shows

The default layout is now two rows, download over upload, so both directions are readable
without opening anything. `BarLayout` moved into SpeedCore so its default and its
migration are covered by tests. A missing or unreadable preference resolves to the
two-row layout, and a stored preference for the old single-number layout is moved across
once, guarded by `barLayoutMigratedV2` so a deliberate re-selection in 2.0 sticks.

`SpeedFormatter.bar` chooses precision from the magnitude of the value **in the unit being
shown**:

| Converted value | Example | Rendered |
|---|---|---|
| not finite, or zero | counters did not move | `0.00` |
| below 0.005 | 0.003 | `<0.01` |
| below 1 | 0.15 | `0.15` |
| below 100 | 5.3 | `5.3` |
| below 1000 | 125 | `125` |
| 1000 and above | 1240 | `1.2G` |

Each band re-checks the one above it, so a value that rounds up to a band's ceiling is
formatted by the next rule: 0.996 is `1.0`, not `1.00`. Strings stay within five
characters, which is what pins the item width.

In megabytes per second the same rules give `0.02` for 0.15 Mbps and `0.66` for 5.3 Mbps.
Version 1.1 printed one decimal at every magnitude, so in that unit everything below
0.4 Mbps rendered as `0.0` and the app looked dead while measuring correctly.

The panel now formats through `SpeedCoreFormatter.panel(_:unit:)` and shows the unit in
its captions, so the bar and the panel can no longer disagree by a factor of eight. Values
that are not speeds — latency in milliseconds, Apple's responsiveness — go through
`scalarTile` and are never converted.

## Emphasis and freshness

`TransferActivityDetector` decides whether a direction is transferring. Entry and exit are
measured on the same statistic, bytes inside a trailing three-second window, with
different thresholds and dwell times: in at 384 KB, out below 128 KB held for eight
seconds, and a three-second minimum. The long exit rides out the silent pauses in a
streamed response; measuring exit on a different statistic than entry produces a detector
that latches on and never releases on a machine whose idle traffic sits near the exit rate.

The upload detector is fed the existing per-packet control allowance, and a matching
`downloadActivityMbps` now exists for the other direction, so the acknowledgements of a
large upload do not light up the download row. `IFCounters` gained `rxPackets` for this.
Displayed rates remain the measured byte rates; the allowance only classifies.

`LiveReadoutModel` decides what is on screen. A transient gap — a late tick, one failed
counter read — keeps the last numbers, dimmed, for `maximumGapSeconds` plus one cadence.
A terminal reason (no interface, sleep) clears immediately. It also owns the recovery
request: `needsRebaseline` fires at most once per staleness episode, because the refresh
loop runs faster than the sampling cadence and repeatedly dropping the baseline would stop
the monitor from ever building a delta.

## Path changes

`PathChangeClassifier` compares two snapshots and reports what actually changed: nothing,
route only, cost, interface set, active interface, or status. Only an active-interface or
status change rebinds the meter. Any change still ends a running capacity test, because
one test must describe one network.

Version 1.1 treated every path callback as a network change. `NWPath` equality fails for
DNS servers, gateways and address changes, so the readout blanked and the sampler
rebaselined for events that left the measured interface untouched — Apple's peer-to-peer
radio coming up for AirDrop, a DHCP renewal, a roam between access points.

## Capacity tests

GO now runs a chain of engines rather than a single provider:

1. `h3.speed.cloudflare.com`, the host Cloudflare's own open-source measurement CLI targets
   by default. HTTP/2, no header gate, no refused byte range.
2. `speed.cloudflare.com`, the host behind the web page, as an independent second path.
3. `/usr/bin/networkQuality`, which reaches whichever Apple endpoint it chooses.

Every request now carries `Referer` and `Origin`. Version 1.1 sent them only with the
metadata request, and the legacy host refuses download sizes between 11,000,000 and
19,999,999 bytes outright when they are absent. The ladder's power-of-two rung at
16,777,216 sits inside that range, which is why some runs failed and their neighbours did
not. `ChunkLadder` additionally steps around the range on that host, so a request never
depends on the headers alone.

`SpeedTestChainPolicy` decides whether to hand over. Only an explicit refusal, a rate
limit or an interception advances the chain; timeouts, cancellation and local faults stop
it, as does any failure after the download phase completed or after 64 MB of validated
payload. Falling through on a timeout would abandon a working provider for one whose
numbers are not comparable.

`SpeedTestRunGate` keeps its ownership rules and its shared 30-second spacing, and its
backoffs are now per engine: a refusal blocks that engine for five minutes, a rate limit
for fifteen, and the chain skips blocked engines instead of walking back into them.
Backoffs travel on the failure as well as the success, because the case that most needs
them is every engine refusing, which throws.

Engine identity is recorded in new optional fields — `endpointHost`, `engineKey`,
`fallbackFrom`, `trigger` — rather than a new `SpeedTestEngineID` case. That enum is a
non-optional stored field: a new case would make 2.0 history undecodable by 1.1, and the
store moves a file it cannot decode aside wholesale.

## Compatibility

The bundle identifier, the store paths, the history envelope version and both existing
`SpeedTestEngineID` cases are unchanged. Every field added to `SpeedTestResult` is
optional. A 2.0 preference file is valid for 1.1: `twoLine` exists there, and unknown keys
are ignored. Rolling back to 1.1 keeps history, outages, preferences and the login item.
