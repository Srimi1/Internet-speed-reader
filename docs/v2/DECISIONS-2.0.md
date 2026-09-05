# Architecture decision records, version 2.0

These add to and, where stated, supersede parts of [the 1.x records](../DECISIONS.md).
Measurements come from one development machine on one connection; they explain the
reasoning rather than establishing constants.

| ADR | Decision |
|---|---|
| 029 | Both directions by default, and precision that follows the displayed unit |
| 030 | Route-only path changes leave the live meter alone |
| 031 | Transient gaps hold the last reading instead of blanking it |
| 032 | Activity is detected per direction on one statistic, with a long exit |
| 033 | Capacity is a chain of free providers, tried in order |
| 034 | Engine identity travels in optional fields, never a new stored enum case |
| 035 | Rejected: a floating overlay, per-process attribution, and several providers |

---

## ADR-029: Both directions by default, and precision that follows the displayed unit

**Context.** The user reported that the app was "not active": the menu bar showed `0.0`.
It was in fact sampling every second throughout. Two display rules combined to hide that.
The single-number layout was the default, so only one direction was ever visible. And
`SpeedFormatter.bar` printed one decimal at every magnitude after converting into the
chosen unit, so with megabytes per second selected, every rate below 0.4 Mbps rendered as
`0.0`. Measured idle traffic on the machine was 0.04 to 6 Mbps.

**Decision.** The default layout is two rows. Precision follows the magnitude of the
converted value: two decimals below 1, one below 100, integers below 1000, then giga. Real
traffic too small to show at that precision renders as `<0.01`; only a genuine zero prints
`0.00`, and an unavailable reading remains an em dash. Each band re-checks the band above
it so rounding cannot produce a string belonging to the next band. The panel formats
through the same unit as the bar, and values that are not speeds are never converted.

**Consequences.** The five-character bound that pins the item width still holds, and the
width samples now include `<0.01` and the giga strings. The measured width of the two-row
layout on the development machine is 58 points, narrower than the single-number layout it
replaces, so the change does not make a crowded menu bar worse. A stored preference for
the single-number layout is migrated once; the layout remains selectable.

---

## ADR-030: Route-only path changes leave the live meter alone

**Context.** `NWPath` equality covers DNS servers, gateways and addresses, so a new
snapshot arrives for events that leave the measured interface untouched. Version 1.1
treated any new snapshot as a network change: it cancelled tests, blanked the readout and
dropped the sampler's baseline. AirDrop, a DHCP renewal or a roam between access points
each cost the display a couple of seconds and the graph its history.

**Decision.** `PathChangeClassifier` names what changed. Only an active-interface or
status change rebinds the meter. The interface set is compared after the exclusions the
selector already applies, so Apple's peer-to-peer radio appearing is route-only, while a
VPN tunnel appearing is not. Every change still ends a running capacity test.

**Consequences.** This supersedes the 1.x rule that route changes reset smoothing and
direction. Sleep, wake and interface changes still do. A test is still never allowed to
span two networks, which is the property that rule was protecting.

---

## ADR-031: Transient gaps hold the last reading instead of blanking it

**Decision.** `LiveReadoutModel` distinguishes a reading that is briefly late from one
that is genuinely gone. Transient reasons keep the last numbers, dimmed, for the sampler's
own gap allowance plus one cadence; terminal reasons clear at once. The model also owns
the recovery request, which fires at most once per staleness episode.

**Reason.** A dash means "no idea", and the app said that on every rebaseline. The latch
matters as much: the refresh loop runs at twice the sampling cadence, so an unlatched
recovery request would drop the monitor's baseline before it could measure a delta, and
the meter would never recover.

---

## ADR-032: Activity is detected per direction on one statistic, with a long exit

**Decision.** `TransferActivityDetector` runs once per direction. Entry needs 384 KB inside
a trailing three-second window; exit needs the same window below 128 KB for eight seconds,
with a three-second minimum active time. The download side uses a new
`downloadActivityMbps` built on `rxPackets`, mirroring the existing upload allowance.

**Consequences.** Entry and exit are the same measurement, so the detector cannot latch on
when a machine's idle traffic happens to sit near the exit rate. The eight-second exit is
sized for streamed responses that go quiet while a model thinks. The existing direction
selector is untouched and still drives the single-number layout's arrow; the detector
drives row emphasis. The thresholds are reasoned from one machine's traffic and should be
re-checked against a capture before they are treated as settled.

---

## ADR-033: Capacity is a chain of free providers, tried in order

**Context.** The single provider returned HTTP 403 and the test simply failed. The cause,
bisected live: the legacy host refuses download sizes between 11,000,000 and 19,999,999
bytes when no `Referer` or `Origin` header is present, and the ladder's power-of-two rung
at 16,777,216 sits inside that range. Version 1.1 sent those headers only with the
metadata request.

**Decision.** Send the headers on every request. Prefer `h3.speed.cloudflare.com`, the
default target of Cloudflare's own open-source measurement CLI, which negotiates HTTP/2
and has no header gate. Keep the legacy host as an independent second path and Apple's
tool as a third. Only an explicit refusal, rate limit or interception advances the chain;
a completed download phase, 64 MB of validated payload, a timeout or a local fault stops
it. Backoffs are per engine and are recorded whether the chain succeeded or gave up.
`ChunkLadder` also steps around the refused range on the legacy host.

**Consequences.** A refusing provider costs one fallback, not a failed test. Apple is last
everywhere: it selects its own endpoint, which can be far away, so its numbers are a second
opinion rather than a substitute — on the development connection it reported roughly a
third of what Cloudflare did. Every provider in the chain is free, needs no account and
sets no published limit; the alternatives that were rejected are in ADR-035.

**Evidence.** Verified from the development machine: the legacy host refuses 16,777,216
bytes with a one-byte body and no headers, and returns the full body with them; the
preferred host returns the full body over HTTP/2 without them, serves metadata, and
confirms a 4 MiB upload with an exact `cf-meta-upload-bytes`.

---

## ADR-034: Engine identity travels in optional fields, never a new stored enum case

**Decision.** `SpeedTestEngineID` keeps exactly its two cases. Which host produced a result
is recorded in the optional `endpointHost`, `engineKey`, `fallbackFrom` and `trigger`
fields, and the engine key lives in a separate type that is never persisted as a
non-optional.

**Reason.** The history store decodes its whole envelope at once and moves a file it cannot
decode aside. A new case in a non-optional field would therefore destroy the user's history
the first time they rolled back to an older build, and the install script keeps a backup
precisely so rolling back is possible.

**Consequences.** A reviewer should reject any change that adds a case to that enum or a
non-optional field to the result.

---

## ADR-035: Rejected alternatives

| Alternative | Rejected because |
|---|---|
| A floating overlay that appears during transfers | The user chose a menu bar that always shows both numbers instead. Row emphasis covers "show me when something is transferring" without a second window. |
| Per-process attribution ("which app is downloading") | No public API exists. The system tool that can do it holds a private entitlement, and polling it as a subprocess cost more than a full core on the development machine. |
| M-Lab NDT7 | Its acceptable-use policy asks automated clients to run a handful of tests a day and publishes every measurement, including the client address, into the public domain. |
| Ookla's CLI | Its licence limits use to a person at a command line and forbids redistribution. |
| Fast.com | Download-biased, no public interface, and it would mean shipping a scraped token. |
| LibreSpeed's public pool | Volunteer servers with no server near the development connection; supportable only as a user-supplied address. |
| Static test files on hosting providers | Download only, and polling someone's courtesy file from a background agent is not defensible. |
