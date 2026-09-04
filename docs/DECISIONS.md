# Architecture decision records

> Privacy note: personal signing, local paths and network metadata in this archived
> document were generalized. Example values are not captured personal data.

This file explains why Internet Speed Reader is built the way it is. Each record states the situation, the choice, what the choice costs, and the evidence that motivated it. The evidence is either the code in this repository, a measurement taken on the development machine on 2026-09-04, or a finding from the pre-build research. Where the approved plan and the shipped code disagree, the code wins and the record says so under a "Deviation" note.

Paths are relative to the repository root. Measurements are from one machine (macOS 26.6.2, Apple Silicon, Xcode 26.6, Swift 6.3.3, SDK 26.5, XcodeGen 2.45.4) on one ISP (Example ISP, Example City, served by Cloudflare Kolkata). Treat them as illustrations of the reasoning, not as constants.

| ADR | Decision | Primary file |
|---|---|---|
| 001 | AppKit `NSStatusItem` with a custom `NSView`, not SwiftUI `MenuBarExtra` | `Sources/App/StatusBar/StatusItemController.swift` |
| 002 | Cloudflare endpoints as the built-in engine, Apple `networkQuality` optional | `Sources/SpeedCore/SpeedTest/Cloudflare/CloudflareSpeedTest.swift` |
| 003 | 64-bit `NET_RT_IFLIST2` counters, never `getifaddrs` | `Sources/SpeedCore/Counters/RouteMessageParser.swift` |
| 004 | One interface chosen from `NWPath`, never a sum | `Sources/SpeedCore/Path/PathSnapshot.swift` |
| 005 | One `URLSession` per stream with `httpMaximumConnectionsPerHost = 1` | `Sources/SpeedCore/SpeedTest/Cloudflare/CloudflareSpeedTest.swift` |
| 006 | Session-level delegate for download byte counting | `Sources/SpeedCore/SpeedTest/Cloudflare/DownloadStream.swift` |
| 007 | Throughput is a sum into one `ByteLedger` sampled on one clock | `Sources/SpeedCore/SpeedTest/Cloudflare/ByteLedger.swift` |
| 008 | Request size from the per-stream rate, two seconds of work per request | `Sources/SpeedCore/SpeedTest/Cloudflare/ChunkLadder.swift` |
| 009 | 1.5 s warm-up discard, trim lowest 30% and highest 10% | `Sources/SpeedCore/SpeedTest/Cloudflare/ThroughputAggregator.swift` |
| 010 | Server processing time subtracted from latency only | `Sources/SpeedCore/SpeedTest/Cloudflare/ServerTiming.swift` |
| 011 | Strict response validation is a hard abort | `Sources/SpeedCore/SpeedTest/Cloudflare/ResponseValidator.swift` |
| 012 | File-backed random upload fixtures | `Sources/SpeedCore/SpeedTest/Cloudflare/UploadFixture.swift` |
| 013 | Link-layer live meter and payload speed test kept separate and labelled | `Sources/App/StatusBar/StatusItemController.swift` |
| 014 | Outage hysteresis: two failures down, one success up, 3 s path debounce | `Sources/SpeedCore/Outage/ConnectivityStateMachine.swift` |
| 015 | Grace windows gate banners, not the ledger; sleep closes; heartbeat | `Sources/SpeedCore/Outage/OutageLedger.swift` |
| 016 | HTTP probes under one 3 s round deadline, no ICMP, no gateway | `Sources/SpeedCore/Probe/ConnectivityProbe.swift` |
| 017 | Injected `TimeSource` and `withDeadline` around every network call | `Sources/SpeedCore/Support/Deadline.swift` |
| 018 | One adaptive number in the bar: 1.3x dominance, 0.15 Mbps floor, 3 s dwell | `Sources/SpeedCore/Counters/ActiveDirectionSelector.swift` |
| 019 | Bar strings: half-up rounding, five characters max, pinned width | `Sources/SpeedCore/Support/Formatters.swift` |
| 020 | Alerts are banner plus red bar plus log, no sound, `.active` level | `Sources/App/NotificationService.swift` |
| 021 | Launch at login on by default, reconciled on every launch | `Sources/App/AppCoordinator.swift` |
| 022 | Versioned atomic JSON files for history and the outage log | `Sources/SpeedCore/Support/AtomicJSONStore.swift` |
| 023 | Apple Development identity, team LOCAL_TEAM_ID, sandbox off, hardened runtime on | `project.yml` |
| 024 | Deployment target macOS 14 | `project.yml` |
| 025 | Swift 6 language mode with per-target default actor isolation | `project.yml` |
| 026 | Repository inside iCloud Drive, build products outside it | `scripts/make-dmg.sh` |
| 027 | UDZO disk image on APFS, staged outside iCloud, app and image signed | `scripts/make-dmg.sh` |

---

## ADR-001: AppKit `NSStatusItem` with a custom `NSView`, not SwiftUI `MenuBarExtra`

**Context.** The menu bar item must draw a coloured dot plus a number in a fixed width, distinguish left click from right click, open and close its panel from code (so that a test finishing while the panel is closed can reopen it — the hook `StatusItemController.reopenPanelForResult()` exists but is not yet called), and keep its position across launches. The research checked `MenuBarExtra` against the MacOSX 26.5 SDK `swiftinterface`: its label is limited to `Text` or `Label<Text, Image>`, it has no API to present or dismiss its window, no click-type distinction, and no access to the underlying `NSStatusItem`. macOS 26 added nothing to it. `NSStatusItem` is not deprecated; only its pre-10.14 forwarding shims are.

**Decision.** `StatusItemController` creates `NSStatusBar.system.statusItem(withLength: 72)`, hosts `StatusItemView` (an `NSView` subclass) as a subview of the button, routes `sendAction(on: [.leftMouseUp, .rightMouseUp])` through one handler, and shows a `.transient` `NSPopover` whose content is `PanelView` inside an `NSHostingController`. `autosaveName` is `com.srimi.internetspeedreader.readout`. SwiftUI is still used for the panel, the gauge and the `Settings` scene, which is the only SwiftUI scene in `Sources/App/InternetSpeedReaderApp.swift`.

**Consequences.** Click routing, button highlighting, and the assign-then-clear dance for the context menu (`statusItem.menu = menu`, `performClick`, then `menu = nil` in `menuDidClose`) are hand written. The two-line layout is drawn directly rather than through `attributedTitle`, which the research reports clips and needs per-display baseline offsets. Placement next to the clock cannot be programmed on macOS; the README documents Command-drag and the autosave name makes the choice stick.

**Evidence.** `Sources/App/StatusBar/StatusItemController.swift` (header comment and `handleClick`), `Sources/App/StatusBar/StatusItemView.swift`. Research report, topic 2, verified items 2, 3, 4 and 7. The critique notes that the open Feedback Assistant bugs cited for `MenuBarExtra` date from 2022 to 2023 and were not re-tested on macOS 26.6; the label-type restriction, which is sufficient on its own, was verified in the SDK.

---

## ADR-002: Cloudflare endpoints as the built-in engine, Apple `networkQuality` optional

**Context.** The user wanted a zero-install engine that reports the Ookla-style tuple: ping, jitter, download, upload, ISP, and server. The research evaluated five sources and found that only `speed.cloudflare.com` returns all of them from one place with a permissive reference implementation (`@cloudflare/speedtest`, MIT). Ookla's CLI is proprietary, restricted to personal command-line use, and only a 2022 build (1.2.0) is downloadable. M-Lab's acceptable-use policy caps automated clients at four tests a day and publishes every measurement under CC0. Fast.com needs a token scraped from a content-hashed JavaScript bundle that rotates on every deploy. LibreSpeed has no maintained public server pool and an LGPL-3.0 backend. Apple's `networkQuality` takes about 26 s, offers no ISP, jitter or progress, and always uses Apple's CDN (a Singapore edge for this Indian client).

**Decision.** `CloudflareSpeedTest` is the built-in engine, using `GET /meta` (with the required `Referer` and `Origin` headers), `GET /__down?bytes=N` and `POST /__up`. `NetworkQualityRunner` spawns `/usr/bin/networkQuality -c -s -M 15` behind the right-click "Apple Deep Test" item, with a hard kill at M plus 10 s. Apple's numbers land in `AppleExtras`, are labelled "Apple CDN" with the endpoint, and are never written into the Cloudflare columns. Tests are on demand only, spaced 30 s apart (`SpeedTestController.minimumSpacing`), with a 15 minute block after a 403 or 429.

**Consequences.** Cloudflare is not a documented third-party API. The `Referer` gate, the 50 MiB per-request cap and the bot rules can change without notice, so decoding is defensive (`CloudflareMeta`), the user agent names the repository, and the Apple engine is the fallback the UI points to when rate limited. Deviation: the plan's ISP fallback chain (`__down` headers, then Apple's `/.well-known/nq` headers, then "Unknown ISP") is not implemented; the code goes straight from `/meta` to `CloudflareMeta.ispDisplayName`, which returns "Unknown ISP" when both `asOrganization` and `asn` are missing. Deviation: the plan's loaded-latency sampler is not implemented; `downloadLoadedLatencyMs` and `uploadLoadedLatencyMs` exist in `SpeedTestResult` but are never assigned. Deviation: the plan's escalating 15 min, 1 h, 6 h backoff is a single 15 minute block in `SpeedTestController.fail`.

**Evidence.** `Sources/SpeedCore/SpeedTest/Cloudflare/CloudflareSpeedTest.swift`, `Sources/SpeedCore/SpeedTest/Cloudflare/CloudflareEndpoints.swift`, `Sources/SpeedCore/Apple/NetworkQualityRunner.swift`, `Sources/App/SpeedTestController.swift`. Live run on 2026-09-04: 176.3 Mbps download, 137.9 Mbps upload, ping 82.8 ms, jitter 15.6 ms, ISP "Example ISP", client Example City, colo Kolkata (CCU), protocol http/1.1, 23.6 s wall time. Research report, topic 1, recommendation and "rejected engines".

---

## ADR-003: 64-bit `NET_RT_IFLIST2` counters, never `getifaddrs`

**Context.** The live meter needs cumulative per-interface byte counters. `getifaddrs` exposes `struct if_data`, whose `ifi_ibytes` and `ifi_obytes` are `u_int32_t` and wrap every 4.29 GB. The sysctl path `NET_RT_IFLIST2` returns `if_msghdr2` records whose `ifm_data` is `struct if_data64`. The research read both APIs back to back on the development machine and found en0 receive bytes of 1,787,888,724 via the 32-bit path and 6,082,856,020 via the 64-bit path, a difference of exactly 2^32. The critique reproduced the wrap independently with `netstat -ib` against a ctypes read of `getifaddrs`.

**Decision.** `SysctlCounterReader` issues `sysctl` with mib `[CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, index]`, retrying once on `ENOMEM`, and hands the raw buffer to `RouteMessageParser`. The parser always advances by `ifm_msglen`, uses `loadUnaligned`, and reads `ifm_data.ifi_ibytes` and `ifi_obytes` only from `RTM_IFINFO2` messages. Passing the interface index in `mib[5]` asks the kernel for a single record on the 1 Hz path.

**Consequences.** The parser is pure and is tested against synthetic buffers, including a counter above 2^32, an odd-length foreign message, a truncated tail, and a zero-length header. `ThroughputCalculator` treats any counter decrease as an interface reset and rebaselines rather than emitting a spike, because a 64-bit counter cannot legitimately wrap in human time. No root is required. A test-builder bug during the build emitted a message shorter than its own header, which the kernel never does; that was fixed in the builder, not the parser.

**Evidence.** `Sources/SpeedCore/Counters/SysctlCounterReader.swift`, `Sources/SpeedCore/Counters/RouteMessageParser.swift`, `Sources/SpeedCore/Counters/ThroughputSampler.swift`, `Tests/SpeedCoreTests/RouteMessageParserTests.swift`. Research report, topic 3, verified items 1 to 4; critique spot-check 3. Validation on 2026-09-04: a 50 MiB download read 154.45 Mbps at the interface against 140.96 Mbps of payload (57,447,424 interface bytes for 52,428,800 payload bytes in 2.976 s).

---

## ADR-004: One interface chosen from `NWPath`, never a sum

**Context.** Interface counters are system wide, and several interfaces carry traffic that is not internet traffic: `lo0` is the machine talking to itself, `awdl0` and `llw0` are Apple's peer-to-peer radios (the research found 34 MB on `awdl0` on an idle host), and a VPN tunnel (`utun*`) increments both the tunnel and the physical interface for the same payload. `NWPath.availableInterfaces` also reports `en0` twice, once per address family, verified during research and again during the build.

**Decision.** `ActiveInterfaceSelector.select` dedupes by index, drops names in `excludedNames` (`lo0`, `awdl0`, `llw0`, `anpi0` to `anpi2`, `bridge0`, `ap1`, `gif0`, `stf0`), and returns the first physical interface (`wifi`, `wiredEthernet`, `cellular`). If no physical interface exists it returns the first tunnel, and the UI labels that case "tunnel payload". `NWPathSource` classifies `.other` interfaces whose names start with `utun`, `ipsec`, `ppp`, `tun`, `tap` or `wg` as tunnels. Interfaces are never summed.

**Consequences.** With a split-tunnel VPN the meter shows the physical interface and ignores the tunnel. With a full-tunnel VPN it shows decrypted tunnel payload, which is a different quantity, so the tooltip and panel say which one is displayed. The plan called for a real VPN connect and disconnect test in M3; the session facts do not record one, so the tunnel branch is covered by unit tests only.

**Evidence.** `Sources/SpeedCore/Path/PathSnapshot.swift`, `Sources/SpeedCore/Path/NWPathSource.swift`, `Tests/SpeedCoreTests/ActiveInterfaceSelectorTests.swift`. Research report, topic 3, verified item 7 and gotchas 10 and 11. Session fact: `NWPath` returned `en0` twice during the counter validation.

---

## ADR-005: One `URLSession` per stream with `httpMaximumConnectionsPerHost = 1`

**Context.** A parallel-stream speed test only measures the link if the streams are separate TCP connections. The critique pointed out two ways `URLSession` silently defeats that: `httpMaximumConnectionsPerHost` defaults to 6, so a seventh task queues, and if the host negotiates HTTP/2 all requests to one origin are multiplexed onto one connection with one congestion window. The build confirmed `speed.cloudflare.com` currently negotiates HTTP/1.1 only, and that a single 25 MiB stream reached 120 Mbps while four parallel streams summed to about 160 Mbps.

**Decision.** Every download stream is its own `DownloadStream`, which owns its own `URLSession` built from `CloudflareSpeedTest.makeSessionConfiguration`, and every upload task in the task group creates its own session. That configuration sets `httpMaximumConnectionsPerHost = 1`, `httpShouldUsePipelining = false`, `waitsForConnectivity = false`, no cache, `Accept-Encoding: identity`, and a user agent that names the repository. The negotiated protocol from `URLSessionTaskMetrics` is stored in `SpeedTestResult.networkProtocol` so a future change to HTTP/2 is visible rather than silent.

**Consequences.** N streams are N connections by construction, so no coalescing detection is needed. Sessions are invalidated at the end of each phase. The cost is N session objects per phase, which is trivial at the default six download and four upload streams.

**Evidence.** `Sources/SpeedCore/SpeedTest/Cloudflare/CloudflareSpeedTest.swift` (header comment, `makeSessionConfiguration`, `runDownloadPhase`, `runUploadPhase`), `Sources/SpeedCore/SpeedTest/Cloudflare/DownloadStream.swift`. Session facts: ALPN accepted http/1.1 only; 120 Mbps single stream versus about 160 Mbps across four; live run with six streams reached 176.3 Mbps. Critique, "missing" item 2.

---

## ADR-006: Session-level delegate for download byte counting

**Context.** The first live run reported a correct upload and a download of 0.0 Mbps. The cause was the convenience API `URLSession.data(for:delegate:)`: it accumulates the body itself and never calls `urlSession(_:dataTask:didReceive:)` on the task-scoped delegate, so the ledger saw no bytes even though the transfer completed.

**Decision.** `DownloadStream` is an `NSObject` conforming to `URLSessionDataDelegate` and is installed as the session-level delegate when its `URLSession` is created, with a serial `OperationQueue`. It counts bytes in `didReceive data`, validates headers in `didReceive response`, captures the protocol in `didFinishCollecting metrics`, and bridges completion back to `async` through a `CheckedContinuation` held behind an `OSAllocatedUnfairLock`. Uploads keep the per-task delegate (`UploadStreamDelegate`) because `didSendBodyData` is delivered to task delegates.

**Consequences.** The download path has more code than the one-line convenience API, and the stream must be invalidated explicitly (`invalidate()`), which the phase does in a `defer`. Byte counts now arrive as data streams in, which is what the 100 ms slice sampler needs.

**Evidence.** `Sources/SpeedCore/SpeedTest/Cloudflare/DownloadStream.swift` (header comment), `Sources/SpeedCore/SpeedTest/Cloudflare/StreamDelegates.swift`. Session fact: bug 1, caught by comparing the app's result with the speed test's own upload figure and a known-good transfer.

---

## ADR-007: Throughput is a sum into one `ByteLedger` sampled on one clock

**Context.** The single biggest gap the critique found in the research was the aggregation rule. The reference client's "0.9 percentile of per-request rate" is a per-request statistic; with six parallel streams each request sees about one sixth of the link, so any average or percentile of per-request rates under-reports by roughly the stream count. Ookla-comparable throughput is total bytes across all streams over a shared wall-clock window.

**Decision.** All streams in a phase call `ByteLedger.add` on one shared counter guarded by `OSAllocatedUnfairLock`. `SliceSampler` reads that counter every 100 ms on the injected clock and records `deltaBytes * 8 / 1e6 / measuredElapsed` as a `ThroughputSlice`. Per-request durations are never used for throughput. A request cancelled at the phase deadline still contributes every byte it delivered because the ledger already counted them.

**Consequences.** Throughput is bytes against a timeline, not against request duration, which is why server processing time is not subtracted from it (ADR-010). The last slice is dropped in `SliceSampler.stop` because it covers a partial interval after the streams stopped. `ByteLedgerTests.concurrentAdds` is the direct regression: eight tasks adding into one ledger must total eight times the per-task bytes.

**Evidence.** `Sources/SpeedCore/SpeedTest/Cloudflare/ByteLedger.swift` (header comment calls this "the single most important design decision in the engine"), `SliceSampler` in `Sources/SpeedCore/SpeedTest/Cloudflare/CloudflareSpeedTest.swift`, `Tests/SpeedCoreTests/SpeedTestMathTests.swift`. Critique, "missing" item 1. Live run: headline 176.3 Mbps, byte-weighted mean 158.7 Mbps, peak 292.1 Mbps, all stored side by side in `SpeedTestResult` so the aggregation choice is auditable.

---

## ADR-008: Request size from the per-stream rate, two seconds of work per request

**Context.** Cloudflare rejects `__down` requests above 50 MiB with a 403 whose body is one byte, so a request cannot simply ask for "a lot". Too small a request is also wrong: each request pays a round trip of idle socket time between completions, and a common mistake is to divide the link rate by the stream count when sizing, which makes every request finish in a fraction of a second and reads fast links low.

**Decision.** `ChunkLadder.size(forPerStreamBytesPerSecond:)` takes the per-stream rate (the probe rate divided by the stream count once, in the phase), multiplies by `targetSecondsPerRequest = 2.0`, rounds up to a power of two, and clamps to `[262_144, 52_428_800]`. An unknown rate starts at `firstProbeBytes = 1_048_576`. A 1 MiB probe request measures the rate before the phase begins. Upload uses the same two-second target to pick the nearest fixture rung (ADR-012).

**Consequences.** Every request keeps its connection busy for about two seconds, so per-request overhead is a small fraction of the phase. Because the clamp equals the verified cap, the byte-cap 403 cannot be triggered by the ladder. Deviation: the plan specified one halving retry on a byte-cap 403; the code classifies that response as `ResponseValidation.byteCapExceeded` but the download loop does not act on it, and the clamp makes the case unreachable.

**Evidence.** `Sources/SpeedCore/SpeedTest/Cloudflare/ChunkLadder.swift`, `runDownloadPhase` and `probeDownloadRate` in `Sources/SpeedCore/SpeedTest/Cloudflare/CloudflareSpeedTest.swift`, `Tests/SpeedCoreTests/SpeedTestMathTests.swift` (`ChunkLadderTests`). Research report, topic 1, verified item 17 (bytes=52428800 returns 200, bytes=104857600 returns 403 with `Content-Length: 1`). Live run used 2048 KiB chunks across six streams.

---

## ADR-009: 1.5 s warm-up discard, trim lowest 30% and highest 10%

**Context.** The first stretch of any transfer is DNS, TCP and TLS setup, then slow start and the socket buffer filling. Including it drags the result below what the link sustains. Individual 100 ms slices are also noisy: a stall produces a near-zero slice, and delegate callback coalescing can bunch bytes into one slice and overstate it.

**Decision.** `ThroughputAggregator.summarize` discards slices with `secondsSincePhaseStart < 1.5`, sorts the rest, drops the lowest 30% and highest 10%, and reports the mean of the remainder as the headline `mbps`. It also reports `meanMbps` (total bytes over total seconds, untrimmed) and `peakMbps` (the 95th percentile slice). Fewer than 10 usable slices is `ThroughputAggregationError.insufficientData`, which the engine turns into `SpeedTestError.insufficientData`; 10 to 29 slices are flagged `Quality.shortSample`.

**Consequences.** The headline is comparable to other speed tests rather than systematically low. A short data-saver phase (5 s download) still produces a number but is flagged rough. The untrimmed mean is stored alongside so a disputed headline can be checked against raw bytes and seconds. The trim constants are the single place to change if the aggregation is ever revisited.

**Evidence.** `Sources/SpeedCore/SpeedTest/Cloudflare/ThroughputAggregator.swift`, `Tests/SpeedCoreTests/SpeedTestMathTests.swift` (`ThroughputAggregatorTests`: warm-up discard, stall trimming, mean cross-check, insufficient data, short-sample flag). Critique, "missing" item 4 (warm-up discard) and item 1 (trimmed statistic). Live run: headline 176.3 Mbps against a mean of 158.7 Mbps, which is the ramp and stalls showing up in the untrimmed figure.

---

## ADR-010: Server processing time subtracted from latency only

**Context.** Cloudflare's `Server-Timing` header reports `cfSpeedEdge` and `cfSpeedWorker` durations, and a cold worker can add hundreds of milliseconds that have nothing to do with the network. The research measured raw time-to-first-byte of 213 to 793 ms on a link whose server-measured TCP RTT was 31 to 39 ms. The older `cfRequestDuration` metric that tutorials mention no longer exists. Throughput, by contrast, is bytes over a wall-clock timeline (ADR-007), so per-request server time has no place in it.

**Decision.** `measureLatency` issues 20 sequential `GET /__down?bytes=0` requests on a dedicated session within a 6 s cap. Each sample is the measured round trip minus `ServerTiming.totalServerMs` (edge plus worker), clamped at zero. The first sample, which pays connection setup, is kept separately and used only if fewer than five warm samples exist. Ping is the median, jitter the mean absolute difference between consecutive samples. The `cfL4` header's `min_rtt` (microseconds) is stored separately as `tcpMinRttMs` and labelled as server-measured TCP RTT. Server time is never subtracted from throughput.

**Consequences.** The displayed ping is the same method speed.cloudflare.com itself uses, so users comparing against the web page see a matching number. ICMP reads lower because it takes a different anycast path, and the app does not pretend otherwise. `cfL4`'s `lost` and `retrans` counters are not shown as packet loss because they describe one short-lived connection and read zero on healthy and mildly lossy links alike.

**Evidence.** `Sources/SpeedCore/SpeedTest/Cloudflare/ServerTiming.swift`, `measureLatency` in `Sources/SpeedCore/SpeedTest/Cloudflare/CloudflareSpeedTest.swift`, `Tests/SpeedCoreTests/SpeedTestMathTests.swift` (`ServerTimingTests`). Latency study on 2026-09-04, 20 samples: raw HTTP median 77.2 ms; minus Server-Timing 52.4 ms; `cfL4 min_rtt` median 46.1 ms; ICMP ping 20 ms; curl TCP connect 34 ms. Conclusion recorded at the time: HTTP minus server time tracks the server's TCP RTT within about 6 ms. Research report, topic 1, verified items 16 and 19, gotchas 10 and 11.

---

## ADR-011: Strict response validation is a hard abort

**Context.** A captive portal or an intercepting proxy can answer `GET /__down?bytes=N` with a 200 and an HTML page. If those bytes were counted, the app would report a plausible-looking speed for a network that has no internet. On `__up`, the `bytes=` query parameter is ignored and an empty POST returns 200, so a 200 alone proves nothing about what was sent.

**Decision.** `ResponseValidator.validateDownload` accepts a response only if the status is 200, `Content-Type` starts with `application/octet-stream`, and `expectedContentLength` equals the requested byte count; anything else is `.intercepted(reason:)`, a 403 with a body of at most one byte is `.byteCapExceeded`, and other 403 or 429 responses are `.rateLimited`. `DownloadStream` cancels the task in `didReceive response` when validation fails. `validateUpload` requires the `cf-meta-upload-bytes` header to be present, positive, and equal to the fixture size. An interception in any stream ends the phase and throws `SpeedTestError.interception`, which the UI shows as "Test blocked" with no number.

**Consequences.** A test can fail where a looser client would show a number. That is intended: an interception error is more useful than a fake result. The upload result carries `uploadVerifiedBytes`, the count the server confirmed, next to the bytes the client sent.

**Evidence.** `Sources/SpeedCore/SpeedTest/Cloudflare/ResponseValidator.swift`, `Sources/SpeedCore/SpeedTest/Cloudflare/DownloadStream.swift`, `Sources/App/SpeedTestController.swift` (`fail`). `Tests/SpeedCoreTests/CloudflareDecodingTests.swift` (`ResponseValidatorTests`). Critique spot-check 2 (empty `__up` POST returns 200 with zero bytes) and "missing" item 17. Live run: 122.7 MB uploaded, all server-confirmed via `cf-meta-upload-bytes`.

---

## ADR-012: File-backed random upload fixtures

**Context.** `URLSession.uploadTask(with:from:)` holds the whole body in memory. A multi-hundred-megabyte upload on a fast link would balloon a menu bar agent's footprint. A custom `InputStream` subclass would avoid that but adds a class of bugs the project did not want in v1. Zero-filled bodies risk being compressed somewhere along the path and reporting a speed the link cannot deliver.

**Decision.** `UploadFixture` pre-generates files of 1, 4, 16 and 32 MiB (`rungs`) under `~/Library/Caches/com.srimi.internetspeedreader/upload/`, filled with `arc4random_buf`, and reuses a file whose size already matches. Each upload request uses `URLSession.upload(for:fromFile:delegate:)` with an explicit `Content-Length`. `rung(forPerStreamBytesPerSecond:)` picks the rung nearest two seconds of per-stream throughput, mirroring ADR-008.

**Consequences.** Upload memory stays flat regardless of link speed. The fixtures occupy up to 53 MiB of cache, which `scripts/uninstall.sh` removes with the rest of the Caches folder. Random content means the fixture cannot be checked into the repository, so it is generated on first use, and `CloudflareSpeedTest` falls back to the temporary directory if the cache directory cannot be created.

**Evidence.** `Sources/SpeedCore/SpeedTest/Cloudflare/UploadFixture.swift`, `Sources/SpeedCore/Support/AppPaths.swift`, `runUploadPhase` in `Sources/SpeedCore/SpeedTest/Cloudflare/CloudflareSpeedTest.swift`, `Tests/SpeedCoreTests/CloudflareDecodingTests.swift` (`UploadFixtureTests`). Critique, "missing" item 6.

---

## ADR-013: Link-layer live meter and payload speed test kept separate and labelled

**Context.** The menu bar reads kernel interface counters, which include TCP and IP headers, TLS records, ACKs, retransmits, and every application on the machine. The speed test counts only the payload bytes this app moved. The two numbers differ by construction. The research measured 11,744,062 interface bytes for a 10,000,000-byte payload (about 17%); the build measured 57,447,424 interface bytes for 52,428,800 payload bytes (9.6%), or 154.45 Mbps versus 140.96 Mbps.

**Decision.** The bar shows link-layer throughput of one interface and says so: the tooltip in `StatusItemController.tooltip()` reads "Link-layer throughput, about 10 percent above payload" and names the interface and "all apps". The panel footer in `PanelView` states that test results measure payload only. The README has a table contrasting the two. The speed test reports payload Mbps. Neither number is adjusted toward the other, and counters are never used as an "internet is up" signal, because LAN traffic keeps flowing during a WAN outage.

**Consequences.** Users will see the bar read higher than a test on the same link. That is documented rather than hidden. The bar answers "is my connection busy" and the test answers "how fast is my connection", and support questions about the gap can be answered by pointing at the label.

**Evidence.** `Sources/App/StatusBar/StatusItemController.swift` (`tooltip`), `Sources/App/Popover/PanelView.swift` (`footer`), `README.md` ("What the numbers mean"). Session fact: 50 MiB validation on 2026-09-04. Research report, topic 3, verified item 9 and gotcha 14. Critique, "missing" item 7 and "risky" item 13.

---

## ADR-014: Outage hysteresis: two failures down, one success up, 3 s path debounce

**Context.** A single failed probe is not an outage; a transient DNS hiccup or a slow response would otherwise turn the bar red several times a day. A satisfied `NWPath` is not proof of internet either: a captive portal where the user chose "Use Without Internet" reports `.satisfied` with no connectivity. An unsatisfied path is trustworthy in the negative direction, but Wi-Fi roaming between access points unsatisfies it for a moment.

**Decision.** `ConnectivityStateMachine` is a pure value type driven by events with `now` and `wallClock` passed in. Two consecutive probe failures (`failuresToConfirm = 2`) open an outage; one success closes it. The outage `start` is stamped at the first failure, not the confirming one, so the duration is honest. A `.satisfied` path only schedules a probe 300 ms later. An `.unsatisfied` path opens an outage after `pathDebounce = 3 s`. A captive portal is its own state with its own `OutageCause`. Probe cadence is 15 s online, 2 s while suspect or down, and 30 s after ten consecutive failures.

**Consequences.** Detection of a hard outage takes two probe rounds, roughly four seconds at the degraded cadence. Recovery is immediate on the first success. Because the machine has no clocks or I/O, every rule is unit tested with a hand-driven clock in `ConnectivityStateMachineTests`, including the honest start stamp, the debounce, the captive portal state and the cadence backoff. `OutageEngine` only supplies time, probes, timers and the ledger.

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

## ADR-017: Injected `TimeSource` and `withDeadline` around every network call

**Context.** Throughput math divides by elapsed time. `Date` moves when NTP corrects the system clock, and timer coalescing plus App Nap make ticks land late by design, so assuming the nominal interval over-reports by the drift. Network calls on a blackholed route can hang indefinitely (ADR-016). Tests need to drive time by hand to exercise ten-second rules in milliseconds.

**Decision.** `TimeSource` provides a monotonic `now()` (`ContinuousClock.Instant`), a `wallClock()` for human-readable stamps, and `sleep(for:tolerance:)`. `SystemTimeSource` is the production implementation; tests inject a fast-forwarding clock. `withDeadline(_:clock:operation:)` races the operation against `clock.sleep` in a throwing task group and throws `DeadlineExceeded` if the timer wins. `ThroughputCalculator.evaluate` takes measured `elapsedSeconds`, refuses intervals under 0.2 s, and rebaselines on gaps over 5 s or rates over 50 Gbps. `LiveThroughputMonitor` sleeps with a 250 ms tolerance and the cadence comes from `PowerPolicy` (1 s on AC, 2 s on battery, 5 s in Low Power Mode).

**Consequences.** Correctness never depends on cadence: a late tick reports the right number because the divisor is measured. App Nap only degrades cadence. `ProcessInfo.beginActivity` with `.userInitiatedAllowingIdleSystemSleep` is held for the app's lifetime as the documented App Nap opt-out, with `LSAppNapIsDisabled` in `Support/Info.plist` as belt and braces.

**Evidence.** `Sources/SpeedCore/Support/TimeSource.swift`, `Sources/SpeedCore/Support/Deadline.swift`, `Sources/SpeedCore/Counters/ThroughputSampler.swift`, `Sources/SpeedCore/Counters/LiveThroughputMonitor.swift`, `Sources/App/PowerPolicy.swift`, `Sources/App/AppCoordinator.swift` (`beginActivity`). `Tests/SpeedCoreTests/ThroughputCalculatorTests.swift` (`usesMeasuredElapsedTime`), `FastClock` in `Tests/SpeedCoreTests/OutageEngineTests.swift`. Research report, topic 3, gotchas 8 and 13.

---

## ADR-018: One adaptive number in the bar: 1.3x dominance, 0.15 Mbps floor, 3 s dwell

**Context.** After using the two-line layout, the user chose a single number that follows the traffic. Download is what most traffic is and what people mean by "my speed", so it is the resting state. During any mixed transfer the quiet direction is still non-zero because of ACKs, and a naive "show the larger one" would flip between arrows several times a second, which is unreadable.

**Decision.** `ActiveDirectionSelector.update` rests on `.download`; it switches to `.upload` only when upload exceeds download by `dominanceRatio = 1.3` and the larger of the two is at least `floorMbps = 0.15`. Once a direction wins it holds for `dwellSeconds = 3.0`. `AppCoordinator.ingest` feeds the selector the raw sample rather than the smoothed value so it reacts the moment a transfer starts, while the displayed number is a 0.5 exponential average. `BarLayout.adaptive` is the default; two-line, one-line and dot-only remain selectable in Settings for crowded or notched menu bars.

**Consequences.** The readout can be up to three seconds stale about direction during an alternating transfer; the test `mixedTrafficSettles` bounds twenty seconds of alternating traffic to at most seven switches. Accessibility text reports "Uploading at" or "Downloading at" so VoiceOver users know which direction is shown.

**Evidence.** `Sources/SpeedCore/Counters/ActiveDirectionSelector.swift`, `Sources/App/AppCoordinator.swift` (`ingest`), `Sources/App/StatusBar/StatusItemView.swift` (`BarLayout`, `updateAccessibility`), `Tests/SpeedCoreTests/ActiveDirectionSelectorTests.swift`. Session fact: user decision recorded as "single adaptive number (download by default, upload only while uploading; 1.3x dominance, 0.15 Mbps floor, 3 s dwell)"; commit "adaptive number + login default".

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

## ADR-022: Versioned atomic JSON files for history and the outage log

**Context.** Speed test history and the outage log must survive relaunches and schema changes without ever crashing at launch. The critique flagged that SwiftData's `ModelContext` is not `Sendable`, which fights Swift 6 language mode, and that an LSUIElement app has no natural `.modelContainer` scene path. `UserDefaults` grows unbounded and is the wrong place for a list.

**Decision.** `AtomicJSONStore<Record>` writes a `{version, records}` envelope with `Data.write(options: .atomic)`, ISO 8601 dates and sorted keys, and caps the list. On load, an unknown version or a decode failure moves the file aside to `.bak` and starts fresh. `outages.json` (cap 500) and `speedtests.json` (cap 200) live under `~/Library/Application Support/com.srimi.internetspeedreader/`. Both `OutageRecord` and `SpeedTestResult` carry a `schemaVersion` field. The bundle identifier never changes because notifications, the login item, the heartbeat key and these paths all key off it.

**Consequences.** There is no migration code in v1; an incompatible file is preserved as `.bak` rather than parsed. `scripts/uninstall.sh` deletes the directory. The store is a plain struct usable from the nonisolated `SpeedCore` target and from tests with a temporary directory.

**Evidence.** `Sources/SpeedCore/Support/AtomicJSONStore.swift`, `Sources/SpeedCore/Support/AppPaths.swift`, `OutageLedger.makeDefault` in `Sources/SpeedCore/Outage/OutageLedger.swift`, `SpeedTestController.init` in `Sources/App/SpeedTestController.swift`, `Tests/SpeedCoreTests/OutageLedgerTests.swift` (`unknownVersionMovedAside`, `persistsAcrossReload`). Critique, "missing" item 9.

---

## ADR-023: Apple Development identity, team LOCAL_TEAM_ID, sandbox off, hardened runtime on, no notarisation

**Context.** Notifications and `SMAppService` key off the code signature. An ad-hoc signature's designated requirement includes the `cdhash`, which changes on every rebuild, so the critique warned that grants would be silently dropped after each reinstall. The only signing identity on the machine is `-`; there is no Developer ID, so notarisation is not possible. App Sandbox buys nothing for a locally installed utility and the sandbox-versus-`Process()` question was contested in the research. Notarisation requires hardened runtime, so turning it off would foreclose that path later.

**Decision.** `project.yml` sets `CODE_SIGN_STYLE: Manual`, `CODE_SIGN_IDENTITY: "-"`, `DEVELOPMENT_TEAM: LOCAL_TEAM_ID`, `ENABLE_HARDENED_RUNTIME: YES`, `ENABLE_APP_SANDBOX: NO` on the app target, and no entitlements block. `scripts/make-dmg.sh` re-signs the staged app with `--options runtime --timestamp=none` and verifies with `codesign --verify --strict`. The test bundle signs ad-hoc (`"-"`) with hardened runtime off. Nothing is notarised in v1.

**Consequences.** A team-anchored designated requirement survives rebuilds, which is why the login item still read `enabled` after two reinstalls. The same argument should hold for the notification grant, but that was never tested: Allow was not clicked during the 1.0.0 session, so notification-grant persistence is unverified. On another Mac the first launch is blocked by Gatekeeper; the DMG's "READ ME FIRST.txt" and the README give the right-click Open workaround and the `xattr -dr com.apple.quarantine` command. The certificate is an Apple Development certificate and will expire; the documented fallback is ad-hoc signing with hardened runtime off and re-granted permissions. Deviation: the plan set `DEVELOPMENT_TEAM: LOCAL_CERT_ID`; that string is the identity's certificate identifier, not the team. The team is the certificate's OU, `LOCAL_TEAM_ID`, and the build failed until the setting was corrected.

**Evidence.** `project.yml`, `scripts/make-dmg.sh`, `scripts/install.sh`. Session facts: signing identity and real team ID; bug 3; the notification prompt appeared from the installed build. Critique, "risky" items 1, 2 and 11. Research report, topic 2, verified items 14 and 16.

---

## ADR-024: Deployment target macOS 14

**Context.** The app needs `NSApp.activate()` (macOS 14) to front Settings and About from an accessory app without the deprecated `activateIgnoringOtherApps`, the `@Observable` macro (macOS 14) for its models, `.contentTransition(.numericText())` on the readouts, `SMAppService` (macOS 13), and `OSAllocatedUnfairLock` (macOS 13). The two `LSUIElement` apps already installed on the development machine both ship `LSMinimumSystemVersion = 14.0`. Going to macOS 26 would gain `NWPath.linkQuality` and Liquid Glass but cut off users for no feature this app needs.

**Decision.** `project.yml` sets `MACOSX_DEPLOYMENT_TARGET: "14.0"` and `Support/Info.plist` sets `LSMinimumSystemVersion` to 14.0. No macOS 26-only API is used. `AppCoordinator.openSettings` guards `showSettingsWindow:` with `#available(macOS 14.0, *)`, which is redundant at this target but harmless.

**Consequences.** The app runs on macOS 14 and later. The SDK is 26.5 and the host is 26.6.2, so any future use of a symbol gated above 14.0 must be wrapped in `#available`. Deviation: the plan mentioned `.glassEffect` under an availability check for the panel background; the code does not use it.

**Evidence.** `project.yml`, `Support/Info.plist`, `Sources/App/AppCoordinator.swift` (`openSettings`, `showAbout`). Research report, topic 2, verified items 11, 12, 18 and the deployment-target recommendation; topic 3, gotcha 16.

---

## ADR-025: Swift 6 language mode with per-target default actor isolation

**Context.** Swift 6 language mode enforces strict concurrency. UI code wants everything on the main actor; measurement code wants to be nonisolated so actors, lock-guarded delegate classes and pure structs can run off the main thread and be tested without a host app. `SWIFT_DEFAULT_ACTOR_ISOLATION` exists in Xcode 26.6's `Swift.xcspec` and maps `MainActor` to `-default-isolation=MainActor`, but Xcode silently ignores unknown build settings, so the plan required proof that the flag reached the compiler.

**Decision.** `SWIFT_VERSION: "6.0"` for every target. `SpeedCore` (a static library) sets `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`, the app sets `MainActor`, and `SpeedCoreTests` sets `nonisolated`. The test bundle depends only on `SpeedCore` and has no `TEST_HOST`, so `xcodebuild test` never launches the menu bar agent. Isolation crossing happens only through `await` on `SpeedCore` async APIs and `AsyncStream` consumption in `AppCoordinator`. Several app classes carry an explicit `@MainActor` as belt and braces; `AppCoordinator`, `AppDelegate` and `StatusItemView` rely on the target default.

**Consequences.** The flag never appears in the `xcodebuild` log, so the plan's "grep the log" check could not work. It was proven empirically instead: a probe that calls a `@MainActor` function synchronously compiles in the app target and fails in `SpeedCore` with "call to main actor-isolated global function in a synchronous nonisolated context". `ENABLE_USER_SCRIPT_SANDBOXING: YES` blocked the static library's Objective-C header copy phase, so `SpeedCore` sets `SWIFT_INSTALL_OBJC_HEADER: NO` and an empty `SWIFT_OBJC_INTERFACE_HEADER_NAME`. Unit tests: 75 passing in 16 suites with no network.

**Evidence.** `project.yml`, `Sources/App/AppCoordinator.swift`, `Sources/SpeedCore/SpeedTest/Cloudflare/DownloadStream.swift` (`@unchecked Sendable` lock-guarded delegate), `Sources/SpeedCore/Outage/OutageEngine.swift` (actor). Session facts: the isolation proof; bug 4; test counts. Research report, topic 2, verified item 20 and gotcha 19.

---

## ADR-026: Repository inside iCloud Drive, build products outside it

**Context.** A working copy may be inside iCloud Drive and contain spaces. iCloud's file provider tags files with extended attributes (`com.apple.fileprovider.fpfs#P`, `com.apple.FinderInfo`), evicts files, and leaves `.icloud` placeholders. During the build, staging the DMG inside the repository baked those attributes into the image, and `codesign --verify` rejected the installed app with "resource fork, Finder information, or similar detritus not allowed".

**Decision.** DerivedData defaults to `$HOME/Library/Developer/Xcode/DerivedData/InternetSpeedReader` in both scripts (`DD` variable), outside iCloud. The generated `InternetSpeedReader.xcodeproj` is git-ignored and regenerated with `xcodegen generate --spec project.yml`. `.gitignore` also excludes `dist/`, `build/`, `*.icloud`, `*.nosync/` and `._*`. The DMG is staged in `mktemp -d` under `$TMPDIR`, copied with `ditto --noextattr --noqtn`, stripped with `xattr -cr`, and re-signed before imaging. Every path in the scripts is quoted.

**Consequences.** Nothing that Xcode or `hdiutil` produces is synced by iCloud. Anyone building this repository elsewhere should keep the same split. Deviation: the plan staged the DMG in `build/dmg` inside the repository; the code moved staging outside iCloud after the signature failure.

**Evidence.** `scripts/install.sh`, `scripts/make-dmg.sh` (staging comment), `.gitignore`. Session fact: bug 2. Plan, "Build, sign, install" and "Risks and mitigations" (iCloud Drive).

---

## ADR-027: UDZO disk image on APFS, staged outside iCloud, app and image signed

**Context.** v1.0.0 ships as a drag-to-install disk image. `hdiutil` is present on every Mac; `create-dmg` is not installed and is not needed. The image must contain a signed app whose signature still verifies after Finder copies it to `/Applications`, plus a first-launch note because the build is not notarised.

**Decision.** `scripts/make-dmg.sh` regenerates the project, builds Release, copies the app into the temporary staging folder, adds a symbolic link to `/Applications` and a "READ ME FIRST.txt" with the Gatekeeper workaround, strips extended attributes, re-signs with the Apple Development identity using `--options runtime --timestamp=none`, verifies strictly, then runs `hdiutil create -volname "Internet Speed Reader" -srcfolder "$STAGING" -ov -format UDZO -fs APFS`. It verifies the image with `hdiutil verify`, signs the image with the same identity on a best-effort basis, and prints the size and SHA-256. The version comes from `MARKETING_VERSION` in `project.yml`, giving `dist/InternetSpeedReader-1.0.0.dmg`.

**Consequences.** The image is compressed and read only. The README and the in-image note both tell users on other Macs to right-click Open once or remove the quarantine attribute. Deviation: the plan specified `-fs HFS+`; the script uses APFS. Deviation: the plan's optional Finder window layout with a background image was not done.

**Evidence.** `scripts/make-dmg.sh`, `README.md` ("Install"). Session facts: release PR #1 merged into `main` (merge commit d0ee6db), tag v1.0.0, GitHub release with `InternetSpeedReader-1.0.0.dmg`, 1.5 MB (1,564,806 bytes), SHA-256 `4b11408d3d5d5c8e9d99d45311e8f3eb874048346fe0228d3e9609e353282f46`. Plan, "DMG packaging".

---

## Rejected alternatives

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
| Percentile or average of per-request rates | Under-reports by roughly the stream count | Sum into one ledger on one clock (ADR-007) |
| Chunk size divided by stream count | Requests finish too fast; fast links read low | Per-stream sizing, two seconds per request (ADR-008) |
| Raw time-to-first-byte as ping | Inflated by worker cold starts, 213 to 793 ms in research | Subtract `Server-Timing` (ADR-010) |
| Subtracting server time from throughput | Throughput is bytes over a timeline, not per-request duration | Latency only (ADR-010) |
| `cfL4` `lost` and `retrans` as packet loss | Zero on healthy and mildly lossy links alike | Not shown |
| Accepting any 200 as download bytes | A captive portal's HTML would be measured as speed | Hard abort on validation failure (ADR-011) |
| In-memory `Data` upload bodies | Whole body held in RAM | File-backed fixtures (ADR-012) |
| Custom `InputStream` upload body | More code and bug surface than v1 needed | `upload(for:fromFile:)` (ADR-012) |
| Reconciling the live meter to the speed test | They measure different layers | Separate, labelled numbers (ADR-013) |
| Counters as an "internet is up" signal | LAN traffic flows during WAN outages | Active HTTP probe (ADR-014, ADR-016) |
| Trusting a satisfied `NWPath` | A captive portal satisfies the path | Probe on every satisfied path (ADR-014) |
| ICMP ping (raw or `SOCK_DGRAM`) | Unverified end to end; different path from the servers users compare against | HTTP probes and HTTP latency (ADR-016, ADR-010) |
| Probing the default gateway | Local-network traffic, triggers the privacy prompt | Off-subnet endpoints only (ADR-016) |
| `Date` for elapsed time | Moves on NTP correction | `ContinuousClock` via `TimeSource` (ADR-017) |
| Dividing by the nominal tick interval | Coalesced timers land late and over-report | Measured elapsed time (ADR-017) |
| Showing the larger of download and upload each tick | Flips several times a second on mixed traffic | Dominance ratio, floor and dwell (ADR-018) |
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

## Deviations from the approved plan, collected

| Plan said | Code does | Record |
|---|---|---|
| `DEVELOPMENT_TEAM: LOCAL_CERT_ID` | `DEVELOPMENT_TEAM: LOCAL_TEAM_ID`; LOCAL_CERT_ID is the certificate identifier | ADR-023 |
| Verify the isolation flag by grepping the build log | Proven by a compile probe; the flag never appears in the log | ADR-025 |
| No mention of `ENABLE_USER_SCRIPT_SANDBOXING` | Set to YES, with `SWIFT_INSTALL_OBJC_HEADER: NO` on `SpeedCore` | ADR-025 |
| Stage the DMG in `build/dmg`, `-fs HFS+` | Stage in `mktemp -d` outside iCloud, `-fs APFS`, `ditto --noextattr`, `xattr -cr`, re-sign | ADR-026, ADR-027 |
| ISP fallback chain: `/meta`, `__down` headers, Apple `nq`, "Unknown ISP" | `/meta` then "Unknown ISP" | ADR-002 |
| Loaded latency sampled during throughput phases | Fields exist in `SpeedTestResult`; never populated | ADR-002 |
| 15 min, 1 h, 6 h backoff on 403 or 429 | Single 15 minute block | ADR-002 |
| One halving retry on a byte-cap 403 | Classified as `.byteCapExceeded`, not retried; clamp makes it unreachable | ADR-008 |
| Two-line layout as the default | Adaptive single number as the default | ADR-018 |
| Login item registered on demand | Reconciled against `launchAtLoginWanted` (default true) on every launch | ADR-021 |
| Liquid Glass panel background under `#available(macOS 26)` | Not used | ADR-024 |
| Real VPN connect and disconnect exercised in M3 | Not recorded in the session facts; covered by unit tests only | ADR-004 |
