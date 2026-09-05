# Platform research: verified facts for maintainers

**2026-09-05 update:** The research below preserves the v1.0 observations and interpretations. Earlier claims that HTTP 403 proves a byte cap or rate limit are superseded: v1.1 received HTTP 403 for a 16 MiB download, and its cause remains unknown. The 50 MiB ceiling is a conservative client choice, not a published endpoint limit. Only HTTP 429 triggers the 15-minute backoff; HTTP 403 is an explicit refusal. See [current verification](VERIFICATION-1.1.md).

Date of every fact below: 2026-09-04, unless a line says otherwise.

Every fact carries one of two tags.

| Tag | Meaning |
|---|---|
| VERIFIED | Run on the development host on 2026-09-04 (curl, a Swift probe, the built app, or the unit tests). |
| FROM DOCS | Read from Apple headers, the SDK swiftinterface, a vendor page, or a third-party source. Not executed here. |

Ground truth, in order: the code in `Sources/`, `Tests/`, `project.yml` and `scripts/`; the measurements from the build session; the approved plan; the three research reports and their critique. Where the plan and the code disagree, the code wins and the disagreement is listed in the last section.

The original probes ran on an Apple silicon development Mac with the Swift 6 and Xcode 26 toolchain. Network-dependent observations came from one connection and are not universal constants. Client identity, location and ISP details are omitted from this public report.

## 1. Cloudflare speed endpoints

All three endpoints are hardcoded in `Sources/SpeedCore/SpeedTest/Cloudflare/CloudflareEndpoints.swift`. None of them is a documented, versioned API. They are the endpoints the speed.cloudflare.com web page uses, and the reference client `@cloudflare/speedtest` (npm v1.13.1, MIT) is the only specification.

| Endpoint | Method | Purpose in this app | Code |
|---|---|---|---|
| `https://speed.cloudflare.com/meta` | GET | ISP name, client city, serving colo | `CloudflareEndpoints.metaRequest()` |
| `https://speed.cloudflare.com/__down?bytes=N&isr=<nonce>` | GET | Download chunks; `bytes=0` for latency | `CloudflareEndpoints.download(bytes:nonce:)` |
| `https://speed.cloudflare.com/__up` | POST | Upload chunks | `CloudflareEndpoints.upload` |

### 1.1 `/meta`

- VERIFIED: A plain `GET /meta` returns HTTP 403 with body `{}`. A browser User-Agent alone does not help. Sending only `Referer: https://speed.cloudflare.com/` returns 200. Sending only `Origin: https://speed.cloudflare.com` also returns 200. One of the two headers is required and sufficient. The code sends both.
- VERIFIED: Metadata includes `hostname`, `clientIp`, `httpProtocol`, `asn`, `asOrganization`, client location fields and a `colo` object. The public test fixture uses synthetic values and a documentation-only IPv6 address; no captured client metadata is committed.
- The fields are polymorphic relative to older write-ups: `asn` is a JSON number, `latitude` and `longitude` are strings, and `colo` is an object where older clients expect a bare IATA string. `CloudflareMeta.init(from:)` in `CloudflareMeta.swift` accepts `asn` as Int or String and `colo` as object or String. `Tests/SpeedCoreTests/CloudflareDecodingTests.swift` covers the live shape, the legacy shape, and the `{}` body.
- The 403 gate is a bot-management rule, not a contract. It can change silently, and the failure is silent: an empty object decodes fine and the ISP display would go blank. `CloudflareMeta.ispDisplayName` degrades to `AS<asn>` and then to `"Unknown ISP"` rather than an empty string.
- VERIFIED: The colo in `/cdn-cgi/trace` (MAA in one run) can differ from the colo that served `__down` and `/meta` (CCU) because they are separate anycast resolutions. `/cdn-cgi/trace` carries no ASN and no ISP name. The app does not use it.

### 1.2 `__down`

- VERIFIED: `__down?bytes=10000000` returns 200, `Content-Type: application/octet-stream`, `Cache-Control: no-store, no-transform`, `Access-Control-Allow-Origin: *`, and exactly the requested byte count.
- VERIFIED: Response headers on `__down` include `asn`, `cf-meta-ip`, `cf-meta-request-time` (epoch ms), `city`, `colo`, `country`, `latitude`, `longitude`, `postalCode`, `timezone`, and `CF-RAY` whose suffix is the colo. They give ASN and city without the Referer trick, but not the ISP company name. Only `/meta` has `asOrganization`.
- VERIFIED: Byte cap. `bytes=52428800` (50 MiB) returns 200. `bytes=100000000`, `bytes=104857600`, and `bytes=1000000000` return 403 with `Content-Length: 1`, not a JSON error. The threshold is undocumented and may change. `ChunkLadder.maxBytes` is `52_428_800`, so the ladder never asks for more. `ResponseValidator.validateDownload` classifies a 403 whose `expectedContentLength <= 1` as `.byteCapExceeded` and any other 403 or a 429 as `.rateLimited`.
- VERIFIED: Extra query parameters are accepted (`__down?measId=123456&bytes=1000` returned 200). The code appends `isr=<nonce>` so every request has a distinct URL.
- The validator requires status 200, a `Content-Type` starting with `application/octet-stream`, and `expectedContentLength == requestedBytes`. Anything else is `.intercepted` and aborts the phase with `SpeedTestError.interception`. A captive portal or ISP interstitial returning HTML is therefore never measured as speed.
- VERIFIED (build session): `URLSession`'s async `data(for:delegate:)` never calls `urlSession(_:dataTask:didReceive:)` on a task-scoped delegate. The first live run reported a correct upload and a download of 0.0 Mbps. `DownloadStream.swift` therefore installs a session-level `URLSessionDataDelegate` and counts bytes in `didReceive data` into a shared `ByteLedger`.

### 1.3 `__up`

- VERIFIED: `POST __up` with a real body (2,048,000 bytes, `Content-Type: application/octet-stream`) returns `100 Continue` then `200 OK` with `Content-Length: 0`. Response headers: `cf-meta-colo`, `cf-meta-request-time`, `cf-meta-upload-bytes: 2048000`, `access-control-expose-headers: server-timing, cf-meta-colo, cf-meta-request-time, cf-meta-upload-bytes`, plus the two Server-Timing headers.
- VERIFIED: `__up` ignores `bytes=`. `POST __up?bytes=10000000` with an empty body returned 200 in about 250 ms with zero bytes uploaded and no `cf-meta-upload-bytes`. An empty POST also returns 200. Copying the `__down` idiom to `__up` produces a fast 200 and a meaningless upload figure with no error. The code never sends `bytes=` on `__up`.
- VERIFIED: `cf-meta-upload-bytes` echoes the byte count the server actually received. `ResponseValidator.validateUpload` requires the header to be present, non-zero, and equal to the bytes sent; otherwise the request is `.intercepted`. The result stores `uploadVerifiedBytes` separately from `uploadBytes`.
- VERIFIED: Upload server processing time is large. `cfSpeedWorker;dur=286` on a 2 MB upload and `dur=103` on a 200 KB upload. This matters for latency measured on `__up`. The app measures latency only on `__down?bytes=0`, and subtracts server time from latency only, never from throughput (throughput is bytes against a wall clock, see `ThroughputAggregator.swift`).
- Upload bodies are pre-generated random files of 1, 4, 16 and 32 MiB (`UploadFixture.rungs`) stored under Caches, sent with `URLSession.upload(for:fromFile:delegate:)` and an explicit `Content-Length`. In-memory bodies would hold the whole payload in RAM; random content prevents compression along the path.

### 1.4 Server-Timing and cfL4

- VERIFIED: The first header is `Server-Timing: cfSpeedEdge;dur=3, cfSpeedWorker;dur=22`. Both values are milliseconds. There is no `cfRequestDuration` metric any more; tutorials that parse it are stale.
- VERIFIED: A cold Worker inflates `cfSpeedWorker` to 335 ms while `cfSpeedEdge` stays at 3 to 5 ms. Without subtraction a "ping" reads 200 to 800 ms on a link whose RTT is about 30 ms.
- VERIFIED: A second header `server-timing: cfL4;desc="?proto=TCP&rtt=30998&min_rtt=29701&rtt_var=12064&sent=5&recv=7&lost=0&retrans=0&sent_bytes=2838&recv_bytes=516&delivery_rate=123026&cwnd=53&unsent_bytes=0&cid=...&ts=108&x=0"` reports the server-measured TCP round trip in microseconds. `ServerTiming.parse` in `ServerTiming.swift` divides `rtt` and `min_rtt` by 1000 and stores them as `tcpRttMs` and `tcpMinRttMs`. The result exposes `tcpMinRttMs`, labelled as server-measured TCP RTT, separately from `pingMs`.
- `lost` and `retrans` describe the single short-lived connection that served one request and read `0` on every healthy and mildly lossy sample seen. They are not a packet-loss measurement and the app never presents them as one.

### 1.5 Protocol and parallelism

- VERIFIED: speed.cloudflare.com negotiates HTTP/1.1 only (ALPN accepted `http/1.1`; `/meta` reports `"httpProtocol":"HTTP/1.1"`). A single 25 MiB stream reached 120 Mbps; four parallel streams summed to about 160 Mbps on the same link.
- `URLSession` would coalesce concurrent requests to one origin onto a single HTTP/2 connection if the host ever switched protocols, and `httpMaximumConnectionsPerHost` defaults to 6. `CloudflareSpeedTest.makeSessionConfiguration` sets `httpMaximumConnectionsPerHost = 1`, `httpShouldUsePipelining = false`, `waitsForConnectivity = false`, `urlCache = nil`, `reloadIgnoringLocalAndRemoteCacheData`, `Accept-Encoding: identity`, and an honest `User-Agent`. Each download stream owns its own `URLSession` (`DownloadStream`), so N streams are N TCP connections by construction. The negotiated protocol from `URLSessionTaskMetrics.transactionMetrics.last?.networkProtocolName` is stored in `SpeedTestResult.networkProtocol` so a future change is visible.
- VERIFIED (historical build session): a complete run produced download, upload and latency measurements, with upload bytes acknowledged by the server. Personal connection measurements and location metadata are excluded. Methodology 2 supersedes the v1.0 aggregation used for that run.

### 1.6 Terms and rate limits

- Nobody found a published policy for third-party native clients hammering speed.cloudflare.com. The mitigations in code are on-demand tests only, an identifying `User-Agent`, and treating any 403 that is not the byte cap, and any 429, as `.rateLimited`. Treat the 403 gate, the byte cap and the header names as things that can change without notice.

## 2. Apple networkQuality

Wrapped by `Sources/SpeedCore/Apple/NetworkQualityRunner.swift` and decoded by `NetworkQualityReport.swift`. It is the optional "Apple deep test", never the primary engine.

### 2.1 The binary

- VERIFIED: `codesign -dv --entitlements - /usr/bin/networkquality` reports `Executable=/usr/bin/networkQuality`. The real name is camelCase. The lowercase path resolves only because the boot volume is case-insensitive. `NetworkQualityRunner.executable` is `"/usr/bin/networkQuality"`.
- VERIFIED: 321,648 bytes, `root:wheel`, identifier `com.apple.networkQuality.cli`, no TeamIdentifier, entitlements including `com.apple.developer.networking.multipath`, `com.apple.CompanionLink` and `com.apple.locationd.*`. It is an Apple platform binary with private entitlements that cannot be replicated in-process.
- VERIFIED: `man networkquality` has no entry on macOS 26.6.2. `/usr/bin/networkQuality -h` is the only reference.
- VERIFIED: It runs non-interactively. Every run was made from a non-tty shell with stdout piped, and `-c` still emitted JSON to stdout with exit 0.

### 2.2 Flags

VERIFIED from `-h` output.

| Flag | Meaning |
|---|---|
| `-c [filename]` | Computer-readable JSON. Stdout only when no filename follows; `-c foo` writes a file. Always use bare `-c`. |
| `-s` | Sequential download then upload instead of parallel. |
| `-M <seconds>` | Maximum runtime. Present in `-h` output but missing from the usage synopsis line. |
| `-I <iface>` | Bind to an interface, e.g. `en0`. |
| `-d` / `-u` | Skip download / skip upload. Both imply `-s`. |
| `-f h1|h2|h3|L4S|noL4S` | Force a protocol. |
| `-C <url>` | Custom configuration URL (`file://` allowed). |
| `-B <instance>` / `-b` | Bonjour server / list Bonjour servers. |
| `-r <host>` | Host or IP override for the config request. |
| `-k` | Disable certificate validation. |
| `-p` | Use iCloud Private Relay. |
| `-S <port>` | Run a local server. |
| `-v` | Verbose. |

The runner passes `["-c", "-s", "-M", "\(maxSeconds)"]` and appends `["-I", interfaceName]` when an interface is given. `maxSeconds` defaults to 15. `AppSettings.appleMaxSeconds` exists and is shown in the Speed Test tab, but `SpeedTestController.startAppleDeepTest` calls `run(interfaceName:)` without it, so every run is `-M 15`.

### 2.3 Timing

- VERIFIED: A default `networkQuality -c` run took 26.18 s wall (measured with `date +%s.%N` wrappers). `-c -M 10` took 12 s. `-c -s -M 12` took 14 s. `-M` is a soft cap: wall time is roughly M plus 2 to 4 s of setup and teardown.
- The runner enforces a hard deadline of `maxSeconds + 10` s: `terminate()`, then `SIGKILL` two seconds later if the process is still running, and `SpeedTestError.timeout(.download)` is thrown. A `ResumeGuard` ensures the continuation resumes exactly once across the termination handler and the deadline task.
- The runner reads both stdout and stderr to end inside `terminationHandler`. The research warns that a child which fills a 64 KB pipe buffer before exit blocks forever if that pipe is unread; the hard deadline above is the backstop for that case.

### 2.4 JSON schema

- VERIFIED, default parallel mode (`-c`): `base_rtt` (Double, ms), `dl_bytes_transferred`, `dl_flows`, `dl_phase_duration`, `dl_phase_start`, `dl_phase_end`, `dl_throughput`, `end_date`, `start_date`, `il_h2_req_resp` (array of ms), `il_tcp_handshake_443`, `il_tls_handshake`, `interface_name`, `lud_foreign_h2_req_resp`, `lud_foreign_tcp_handshake_443`, `lud_foreign_tls_handshake`, `lud_self_h2_req_resp`, `os_version`, `other` (count histograms), `responsiveness` (Double, RPM), `test_endpoint`, `ul_bytes_transferred`, `ul_flows`, `ul_phase_duration`, `ul_phase_start`, `ul_phase_end`, `ul_throughput`.
- VERIFIED, sequential mode (`-c -s`): top-level `responsiveness` disappears and is replaced by `dl_responsiveness` and `ul_responsiveness`; the `lud_*` arrays gain `_dl_` / `_ul_` infixes. Every property of `NetworkQualityReport` is optional for this reason, and `AppleExtras` carries all three responsiveness fields.
- VERIFIED: `dl_throughput` and `ul_throughput` are bits per second (`89465632` was 89.5 Mbps). `NetworkQualityReport.downloadMbps` divides by 1,000,000. Dividing by 8,000,000 would under-report eight times. For contrast, Ookla's CLI reports `bandwidth` in bytes per second.
- VERIFIED: Dates are local time with no zone and no `T`, for example `2026-09-04 16:12:02.900`. `ISO8601DateFormatter` fails on them. `NetworkQualityReport.parseDate` uses `DateFormatter` with `yyyy-MM-dd HH:mm:ss.SSS`, `en_US_POSIX`, and `TimeZone.current`.
- VERIFIED: There is no `isp`, `jitter`, `packet_loss`, `latency`, `idle_latency`, `server_city`, `client_ip` or `error` key in a successful run.
- VERIFIED: The `-v` line "Idle Latency: 184.414 milliseconds" is not the JSON `base_rtt` (163.13 ms in a nearby run). They are different statistics. The app labels `base_rtt` as Apple's base RTT and never writes it into `pingMs` or calls it idle latency.
- FROM DOCS: `responsiveness` is round trips per minute under load, the IETF responsiveness metric (RFC 9097 context). Higher is better. It captures bufferbloat that an idle ping cannot see, which is the whole reason this engine is offered.

### 2.5 Servers and the Apple config endpoint

- VERIFIED: Server selection is Apple-only and not user-facing. Successive runs may select different Apple CDN endpoints and produce different results. The app labels Apple results `Apple CDN · <test_endpoint>` and keeps them separate from Cloudflare results.
- VERIFIED: The Apple network-quality configuration endpoint returns a version, selected endpoint and small-download, large-download and upload URLs. Its headers can include client ASN and ISP metadata. The app does not use those metadata headers; raw responses are excluded from public fixtures.
- VERIFIED: The raw endpoints work directly: `/api/v1/gm/small` returns 200 with 1 byte; `/api/v1/gm/large` is an endless stream (5,848,728 bytes in 3 s under `--max-time 3`); `POST /api/v1/gm/slurp` accepted 204,800 bytes with 200.

### 2.6 Sandbox and `Process()`

- VERIFIED (file text): `/System/Library/Sandbox/Profiles/application.sb` lines 552 to 557 read `(allow file-read* process-exec (subpath "/bin") (subpath "/sbin") (subpath "/usr/bin") (subpath "/usr/sbin"))`. Line 365 allows `process-exec` under `/System`, line 97 inside the app bundle, and line 110 gates outbound network on `com.apple.security.network.client`. The same profile has four `(allow process-exec filter)` clauses around lines 924 to 941 that nobody examined.
- Nobody ran a sandboxed binary that spawned `networkQuality`. "Sandbox allows exec of `/usr/bin`" is confirmed from the profile; "a sandboxed app can run `networkQuality` end to end" is not. This app ships with `ENABLE_APP_SANDBOX: NO` and no entitlements file (`project.yml`), so the question does not arise in v1.
- FROM DOCS: a child created with `posix_spawn` or `NSTask` always inherits its parent's sandbox.

## 3. macOS menu bar stack

### 3.1 SwiftUI MenuBarExtra (rejected)

- VERIFIED (SDK swiftinterface): `MenuBarExtra` is `@available(macOS 13.0, *)`. Its only label types are `Text` and `Label<Text, Image>`. There is no `isPresented` binding, no width parameter, no click-type discrimination, and no `NSStatusItem` accessor. Styles are `.window`, `.menu` and `.automatic`. Every `@available(macOS 26...)` declaration in SwiftUI.swiftinterface is visionOS or immersive-space related; macOS 26 adds nothing to `MenuBarExtra`.
- FROM DOCS: open Feedback reports, all filed in 2022 or 2023.

| Feedback | Problem |
|---|---|
| FB10185203 | No way to programmatically show or hide the `.window` presentation. |
| FB11984872 | No way for a control inside the window to dismiss it. |
| FB10185639 | The status item is not kept highlighted while the window is open. |
| FB10185468 | `.interactiveDismissDisabled()` has no effect. |
| FB10185325 | No style that presents nothing, so a left click cannot run a custom action. |

- FROM DOCS: `.font()` and `.imageScale()` are ignored on the label (Apple Forums thread 726565). `.menu` style pumps a modal event loop while open. An app whose only scene is a `MenuBarExtra` is terminated when the user removes it from the bar.
- The critique's caveat stands: those reports were not re-tested on macOS 26.6. The SDK evidence proves only that no new API was added. The rejection rests on the verified label constraint and the absence of programmatic dismissal, both of which the app needs (custom two-row view, auto-reopen after a test, right-click menu).
- VERIFIED: the two `LSUIElement` apps already installed on this machine (CodexBar, NotchHub) and exelban/Stats all use `NSStatusItem`; CodexBar's binary references `_OBJC_CLASS_$_NSStatusItem` and contains no `MenuBarExtra` symbol.

### 3.2 AppKit NSStatusItem and NSPopover (used)

- VERIFIED (NSStatusItem.h, copyright 1997-2024): the class and `length`, `menu`, `button`, `behavior`, `visible`, `autosaveName` carry no deprecation. Only the pre-10.14 forwarding shims are deprecated: `action`, `doubleAction`, `target`, `title`, `attributedTitle`, `image`, `enabled`, `toolTip`, `sendActionOn:`, `popUpStatusItemMenu:`, `view`. Claims that "NSStatusItem is deprecated" (for example the TahoeMenuDemo README) are false. The same README calls `NSVisualEffectView` deprecated; also false.
- VERIFIED: `NSStatusBarButton : NSButton` (macOS 10.10) adds only `appearsDisabled`; it accepts subviews, which is how `StatusItemView` draws two rows. `NSVariableStatusItemLength = -1.0`, `NSSquareStatusItemLength = -2.0`.
- FROM DOCS: a two-line `attributedTitle` on the button clips and needs display-dependent `baselineOffset` hacks. The app never sets `attributedTitle`; `StatusItemController` adds `StatusItemView` as a subview of `statusItem.button` and pins `statusItem.length` to a width computed from the widest strings (`SpeedFormatter.widestBarSamples`). `monospacedDigit` fonts equalise glyph widths but not string lengths, so a fixed length is what stops the right side of the menu bar from shuffling.
- VERIFIED (NSPopover.h): `NSPopoverBehavior` is `.applicationDefined` (0, default), `.transient` (1, "AppKit will close the popover when the user interacts with a user interface element outside the popover"), `.semitransient` (2). No macOS 26 additions. The app uses `.transient`; a running test continues in `AppCoordinator` when the popover closes. `StatusItemController.reopenPanelForResult()` exists to re-show it but is never called, so the result appears only the next time the popover is opened.
- VERIFIED (NSApplication.h): `NSApp.activate()` is macOS 14.0+; `activate(ignoringOtherApps:)` is marked for deprecation. `SettingsLink` and `openSettings` are macOS 14.0+. `NWPathMonitor: AsyncSequence` is macOS 14.0+. These are the reasons for `MACOSX_DEPLOYMENT_TARGET: "14.0"`.
- FROM DOCS: menu bar position next to the clock cannot be programmed. Ordering is user-controlled by Command-drag and persisted per `autosaveName` (`com.srimi.internetspeedreader.readout` in code).

### 3.3 Tahoe menu bar

- FROM DOCS: the macOS 26 menu bar is fully transparent by default, so status item content composites straight over the wallpaper. A 26.0 bug leaves the bar not fully transparent when auto-hide is combined with the Transparent style. Users can force a background via System Settings > Menu Bar > "Show menu bar background" or Reduce Transparency. Consequence: use template images and `NSColor.labelColor`, and test over light and dark wallpapers. The app uses semantic colours (`ConnectionDisplayState.dotColor`) and `labelColor` text.
- Note from the build session: Chrome in fullscreen hid the menu bar, so no screenshot of the status item exists from that session.

### 3.4 SMAppService (launch at login)

- VERIFIED (SMAppService.h): `API_AVAILABLE(macos(13.0))`; "Apps that use SMAppService APIs must be code signed"; `mainApp`, `register()`, `unregister()`, `status`, `openSystemSettingsLoginItems()`. Statuses: `.notRegistered`, `.enabled`, `.requiresApproval` (before approval and after the user revokes it), `.notFound`. Errors: `kSMErrorAlreadyRegistered`, `kSMErrorLaunchDeniedByUser`, `kSMErrorInvalidSignature` (`= 3` per SMErrors.h). The `/Applications` recommendation in the header applies to LaunchDaemons, not `mainApp`.
- FROM DOCS: registrations live in the BackgroundTaskManagement database (`sudo sfltool dumpbtm`) keyed by bundle identifier, path and signing info. Moving or deleting the bundle flips status to `.notFound`.
- VERIFIED (build session, bug 6): registering only on first run is wrong. After the next reinstall `SMAppService.mainApp.status` read `.notFound` because BTM recorded the replaced bundle. The fix is `AppCoordinator.reconcileLaunchAtLogin()`: on every launch from `/Applications`, compare `AppSettings.launchAtLoginWanted` (default `true`) with the live status and call `register()` or `unregister()` to match. Verified enabled across two reinstalls.
- Code details: `LoginItemManager.setEnabled` treats `kSMErrorAlreadyRegistered` as success; `.requiresApproval` routes the user to `openSystemSettingsLoginItems()`; `scripts/uninstall.sh` runs the app with `--unregister-login-item` before deleting the bundle because the registration keys off the bundle (`AppDelegate.handleCommandLineFlags`).
- The critique's ad-hoc warning: an ad-hoc signature's designated requirement includes the cdhash, which changes on every rebuild, so TCC and BTM grants can silently churn. The project signs with the Apple Development identity, whose team-anchored requirement is stable across rebuilds.

### 3.5 UNUserNotificationCenter

- FROM DOCS (Apple Forums 724249, 649583, 679326; notifee issue 260): `UNUserNotificationCenter.current()` from a process without a real bundle throws `NSInternalInconsistencyException: 'bundleProxyForCurrentProcess is nil: mainBundle.bundleURL'`. This is an ObjC exception, not an `NSError`; `try` cannot catch it. `swift run` and bare binaries crash. Always test from the built `.app`.
- VERIFIED (UNUserNotificationCenter.h): `macos(10.14)`; the delegate "can only be set from an application"; `willPresentNotification` must call its handler promptly or the notification is dropped; `.alert` presentation is deprecated since macOS 11 in favour of `.banner` and `.list`; `didReceiveNotificationResponse` requires the delegate to be set before `applicationDidFinishLaunching` returns; `.criticalAlert` needs an Apple-granted entitlement.
- FROM DOCS: `.timeSensitive` interruption level needs the `com.apple.developer.usernotifications.time-sensitive` entitlement. `NotificationService` uses `.active`, which Focus modes can hide; the red menu bar item is the guaranteed signal.
- Code: `NotificationService.bootstrap()` sets the delegate inside `AppCoordinator.start()` from `applicationDidFinishLaunching`; `requestAuthorization(options: [.alert])` only (no sound, no badge, no critical); `content.sound = nil`; `willPresent` returns `[.banner, .list]`; the restore notification removes the delivered drop notification first so the pair collapses.
- FROM DOCS: the permission dialog does not appear for an unsigned binary. Ad-hoc is a signature, but see 3.4 for why the team identity was chosen.
- VERIFIED (build session): the notification permission prompt appeared from the installed `/Applications` build, which proves the bundle and signature are correct. The user had not yet clicked Allow at the time of writing.

### 3.6 Signing, Swift 6 and build settings

- VERIFIED: A local Apple Development certificate was used for the original development build. Its personal identity and team are intentionally omitted; public builds use local overrides or ad-hoc signing.
- VERIFIED (build session, bug 3): the certificate CN suffix is not the team ID. A local `DEVELOPMENT_TEAM` override must use the certificate OU.
- VERIFIED (Swift.xcspec in Xcode 26.6): `SWIFT_DEFAULT_ACTOR_ISOLATION` is an enumeration `(nonisolated, MainActor)`, default `nonisolated`, and `MainActor` maps to `-default-isolation=MainActor`. `SWIFT_APPROACHABLE_CONCURRENCY` has `Condition = EFFECTIVE_SWIFT_VERSION in (4, 4.2, 5)` and is a no-op under `SWIFT_VERSION = 6.0`. Xcode's own new-project template still defaults to `SWIFT_VERSION = 5.0`.
- VERIFIED (build session): the flag never appears in the xcodebuild log, so the plan's `grep -c -- '-default-isolation=MainActor'` check cannot pass. It was proven empirically instead: a probe calling a `@MainActor` function synchronously compiles in the app target and fails in `SpeedCore` with "call to main actor-isolated global function in a synchronous nonisolated context".
- VERIFIED (build session, bug 4): `ENABLE_USER_SCRIPT_SANDBOXING: YES` blocked the static library's Objective-C header copy phase. `SpeedCore` sets `SWIFT_INSTALL_OBJC_HEADER: NO` and an empty `SWIFT_OBJC_INTERFACE_HEADER_NAME`.
- VERIFIED (build session, bug 2): staging the DMG inside iCloud Drive baked `com.apple.fileprovider.fpfs#P` and `com.apple.FinderInfo` extended attributes into the image; `codesign --verify` on the installed app then failed with "resource fork, Finder information, or similar detritus not allowed". `scripts/make-dmg.sh` stages in `mktemp -d` outside iCloud, copies with `ditto --noextattr --noqtn`, runs `xattr -cr`, and re-signs before `hdiutil create`.
- VERIFIED (build session, bug 5): `NumberFormatter`'s default half-even rounding turned 84.25 into "84.2", and values at or above 10 Gbps produced a six-character string that broke the fixed width. `SpeedFormatter.bar` uses `.halfUp` and drops the decimal above 10 G.
- VERIFIED: `spctl --status` is `assessments enabled`. A locally built bundle never gets `com.apple.quarantine`, so it launches without a Gatekeeper prompt. The distributed DMG is not notarised; other Macs need the right-click Open dance or `xattr -dr com.apple.quarantine`.
- VERIFIED: 75 unit tests in 16 suites pass with no network and no `TEST_HOST` (`SpeedCoreTests` depends only on `SpeedCore`).

## 4. Network monitoring

### 4.1 Interface byte counters

- VERIFIED (`$SDK/usr/include/net/if_var.h`): `struct if_data` at line 151 has `u_int32_t ifi_ibytes` / `ifi_obytes` at lines 170 and 171. `struct if_data64` at line 189 has `u_int64_t` at lines 208 and 209. `getifaddrs` exposes the 32-bit struct. `struct if_msghdr2` (`net/if.h` line 202) carries `struct if_data64 ifm_data` at line 213, which is what `sysctl NET_RT_IFLIST2` returns.
- VERIFIED (Swift constants printed on this host): `if_data` = 96 bytes, `if_data64` = 128, `if_msghdr` = 112, `if_msghdr2` = 160, `RTM_IFINFO2` = 18 (0x12), `NET_RT_IFLIST2` = 6.
- VERIFIED, the wrap: reading both APIs back to back for `en0` gave rx = 1,787,888,724 via `getifaddrs`/`if_data` and rx = 6,082,856,020 via `NET_RT_IFLIST2`/`if_data64`. The difference is 4,294,967,296, exactly 2^32. tx matched (1,805,371,232) because it had not yet crossed 2^32. The critique repeated the check independently: `netstat -ib` 6,127,937,389 vs 32-bit 1,832,971,304, a difference of 4,294,966,085 (2^32 minus about 1.2 KB of traffic between reads). The 32-bit counter had already wrapped once on a normally used laptop. `RouteMessageParserTests` asserts a counter of `6_082_856_020` survives parsing.
- Walk rules, both encoded in `RouteMessageParser.swift`: advance the offset by `ifm_msglen`, never by `MemoryLayout<if_msghdr2>.size`, because the buffer mixes message types of different lengths; and use `loadUnaligned`, because route messages carry no alignment guarantee. Read `if_msghdr2` only when `Int32(header.ifm_type) == RTM_IFINFO2`. A zero length breaks the loop; a length past the buffer end is treated as truncation.
- `SysctlCounterReader` uses mib `[CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, index]`; `index == 0` returns every interface, a non-zero index returns one record (what Stats does). A two-call sysctl can fail with `ENOMEM` when the table grows between calls; the reader retries once.
- VERIFIED (build session, bug 7): a test builder once emitted a route message shorter than its own header. The kernel never does this. It was a test bug, not a parser bug; the builder now uses at least the header size.
- Interface bytes exceed application payload. VERIFIED: 11,744,062 interface bytes for a 10,000,000-byte payload (about 17%) in the research run; 57,447,424 interface bytes for 52,428,800 payload bytes in 2.976 s during the build session, 154.45 Mbps link-layer against 140.96 Mbps payload, 9.6% overhead. The harness driving the real `LiveThroughputMonitor` read 88 to 148 Mbps during that transfer and 0.01 Mbps idle. Cross-check from the research run: counter-delta 65.41 Mbps vs `networkQuality` 64.78 Mbps. The menu bar shows link-layer throughput and the speed test shows payload; the two are labelled and never reconciled.
- Counters are system-wide, not per-app. Per-process attribution needs `com.apple.private.network.statistics` (VERIFIED on `/usr/bin/nettop`'s entitlements), which third-party apps cannot obtain. `ifstat` is not installed on stock macOS.
- VERIFIED: `awdl0` carried 34 MB on an idle host (AirDrop, AirPlay, Continuity). Summing all interfaces folds Apple's peer-to-peer radio into the internet number. With a VPN up the same payload increments both `utun*` and the physical interface. `ActiveInterfaceSelector.excludedNames` is `lo0, awdl0, llw0, anpi0, anpi1, anpi2, bridge0, ap1, gif0, stf0`; tunnel prefixes are `utun, ipsec, ppp, tun, tap, wg`; a physical interface always wins and a tunnel is used only when it is the only thing left. Interfaces are never summed.
- Counters reset when an interface goes away (Wi-Fi toggle, dock, VPN, sleep). `ThroughputCalculator` rebaselines instead of emitting when a counter decreases, when the gap exceeds `staleGapSeconds` (5.0), or when the rate exceeds `sanityCeilingMbps` (50,000); it returns `.tooSoon` under `minimumIntervalSeconds` (0.2). The rate always divides by measured `ContinuousClock` elapsed time, never by the nominal tick, and never uses `Date`.

### 4.2 NWPathMonitor and NWPath

- VERIFIED (live on this host): `status=satisfied`, `isExpensive=false`, `isConstrained=false`, `linkQuality=good`, `isUltraConstrained=false`, `availableInterfaces=["en0/wifi/idx11", "en0/wifi/idx11"]`, `gateways=["192.168.1.1:0", "fe80::...%en0"]`. `en0` appears twice, once per address family. `ActiveInterfaceSelector.select` dedupes by index first.
- VERIFIED: `NWInterface.index` 11 matched `netstat -ib`'s `<Link#11>` for `en0`, so NWPath hands the live meter the exact sysctl key with no SystemConfiguration dependency. `route -n get default` and `scutil` agreed on `en0`.
- FROM DOCS: `.satisfied` means a path exists, not that the internet works. A captive portal after "Use Without Internet" reports `.satisfied`. The negative (`.unsatisfied`) is trustworthy; the positive is not. `ConnectivityStateMachine` never sets online from a path event; a satisfied path only schedules a probe 300 ms later. An unsatisfied path opens an outage only after a 3 s debounce (`Config.pathDebounce`).
- VERIFIED (SDK): `NWPathMonitor: AsyncSequence` is macOS 14.0+; `NWPathMonitor.Iterator` is explicitly not `Sendable`; `currentPath`'s setter is deprecated since 14. `NWPath.linkQuality` and `isUltraConstrained` are macOS 26.0+ and are not read by `NWPathSource`. `UnsatisfiedReason` has `.notAvailable`, `.cellularDenied`, `.wifiDenied`, `.localNetworkDenied`, `.vpnInactive` (14+); the code maps the first four to strings and everything else to "No network available".
- VERIFIED (SDK): there is no `NetworkMonitor` type in the macOS 26 SDK. The new Swift-native `NetworkConnection` / `NetworkBrowser` API (macOS 26.0+) sits beside `NW*`; `NWPathMonitor` remains the only path-monitoring API.
- The VPN case was never exercised in the research (only `en0` was present). Whether an active tunnel appears beside `en0` or replaces it in `availableInterfaces` is untested; the selector handles both shapes.

### 4.3 Connectivity probe endpoints

VERIFIED with `curl -I` (HEAD), cold, from this host.

| Endpoint | HEAD result | Note |
|---|---|---|
| `http://captive.apple.com/hotspot-detect.html` | 200, 0.464 s | Body is exactly `<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>` (69 bytes) |
| `https://www.gstatic.com/generate_204` | 204, 0.200 s | Zero-byte body |
| `https://connectivitycheck.gstatic.com/generate_204` | 204, 0.219 s | |
| `https://cloudflare.com/cdn-cgi/trace` | 404 | 200 to GET only |
| `https://1.1.1.1/cdn-cgi/trace` | 302 | 200 to GET only |
| `https://www.apple.com/library/test/success.html` | 200, 0.162 s | |

- HEAD and GET are not interchangeable. A HEAD-based probe against either trace endpoint reports "down" on a healthy link 100% of the time. `HTTPProber` sends HEAD to `https://www.gstatic.com/generate_204` (success only on exactly 204) and GET to `http://captive.apple.com/hotspot-detect.html` (200 and body contains "Success" means online via fallback; any other answer means `.captivePortal`). The fallback stays on plain HTTP on purpose: a portal returns its own 200 with different HTML, which the body check catches. `Support/Info.plist` carries an `NSAppTransportSecurity` exception for `captive.apple.com`; without it the plain-HTTP request fails every time.
- VERIFIED: URLSession probe timing (ephemeral, `waitsForConnectivity=false`, 2 s request timeout, HEAD): gstatic 222 ms cold, captive.apple.com 344 ms, gstatic 57 ms on the second call over the same session. Connection reuse cuts probe cost about four times; the prober keeps one long-lived session.
- VERIFIED (build session): the real prober read 216 ms cold then 46 to 49 ms warm on a healthy link, and failed via the deadline at 3003 to 3006 ms against blackholed `192.0.2.1` (round budget 3000 ms).
- `waitsForConnectivity` defaults to true on some configurations and makes a probe hang instead of fail. A cached 204 is served without touching the network. `HTTPProber.makeSession` sets `waitsForConnectivity = false`, `timeoutIntervalForRequest = 2`, `timeoutIntervalForResource = 3`, `reloadIgnoringLocalAndRemoteCacheData`, `urlCache = nil`, `httpMaximumConnectionsPerHost = 2`.
- Hysteresis in code: `failuresToConfirm = 2`, one success clears; cadence 15 s online, 2 s degraded, 30 s after 10 consecutive failures; notify after 10 s; grace 20 s after wake, 15 s after interface change, 10 s after launch; outages under 3 s are not logged. Byte counters are never used as an "internet is up" signal because LAN traffic keeps flowing during a WAN outage.

### 4.4 NWConnection and deadlines

- VERIFIED: an `NWConnection` to blackholed `192.0.2.1:443` (TEST-NET-1) never reached `.failed` or `.waiting`; the state handler stayed silent until a 4 s semaphore fired at 4005 ms. The control connection to `1.1.1.1:443` reached `.ready` in 32 ms. The research's "`.preparing` eventually flips to `.waiting`" phrasing is wrong in practice; never build a state machine that waits for NWConnection to report failure.
- `Sources/SpeedCore/Support/Deadline.swift` races every network call against a `TimeSource` sleep in a throwing task group and throws `DeadlineExceeded`. `HTTPProber` gives the whole round one 3 s budget (`roundBudget`), with 1.5 s for the primary (`primaryBudget`) and the remainder for the fallback, so the 2 s failure cadence stays reachable on a blackholed route.
- The app uses no `NWConnection` at all; latency in the speed test is HTTP over URLSession.

### 4.5 Local Network privacy

- FROM DOCS (TN3179): a local network is an IP network on a broadcast-capable interface (Wi-Fi, Ethernet; not WWAN, not VPN). Any address on it, all multicast (`224.0.0.0/4`, `ff00::/8`) and `255.255.255.255` count. The control "doesn't restrict an app from talking to the Internet", so probing gstatic, captive.apple.com or 1.1.1.1 never triggers the prompt. It is enforced as a packet filter deep in the stack, so BSD sockets do not bypass it.
- Corollary: probing the default gateway (`192.168.1.1` here) is local-network traffic and would trip the prompt or be filtered. Never add a "can I reach my router" check. Multicast and broadcast additionally need the managed `com.apple.developer.networking.multicast` entitlement.
- FROM DOCS: macOS 26 has live bugs where a local-network grant is ignored after reboot and where some apps never get the prompt despite `NSLocalNetworkUsageDescription`. Another reason to keep every probe off-subnet. The app has no local probes and no `NSLocalNetworkUsageDescription`.

### 4.6 App Nap and timers

- FROM DOCS (Energy Efficiency Guide for Mac Apps): "App Nap automatically throttles timers regardless of which API was used to create the timers." Switching from `Timer` to `DispatchSourceTimer` buys nothing. An `LSUIElement` agent with no window is a prime App Nap candidate. `ProcessInfo.beginActivity(options:reason:)` is the documented opt-out; Apple's guidance is a non-zero tolerance on every non-UI timer.
- Code: `AppCoordinator.beginActivity()` holds `ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Live link throughput")` for the app's lifetime; `Support/Info.plist` sets `LSAppNapIsDisabled` as belt and braces. `LiveThroughputMonitor` sleeps with `tolerance: .milliseconds(250)`; `PowerPolicy` chooses 1 s on AC, 2 s on battery, 5 s in Low Power Mode. Because every rate divides by measured elapsed time and gaps over 5 s are discarded, throttling degrades cadence, never correctness.
- Sleep and wake: `NSWorkspace.willSleepNotification` pauses the monitor and suspends the outage engine (closing any open outage with `endReason: .sleep`); `didWakeNotification` resets the baseline, restarts the monitor and resumes the engine with the 20 s grace.

### 4.7 ICMP

- VERIFIED: `socket(AF_INET, SOCK_RAW, IPPROTO_ICMP)` as uid 501 fails with `EPERM`; `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)` succeeds. `/sbin/ping` is `-r-xr-xr-x root:wheel` with no setuid bit. So ICMP without root is possible on macOS, which is what Apple's SimplePing uses. The critique notes only the socket call was verified, not an echo round trip, and that the kernel rewrites the ICMP identifier on DGRAM sockets so naive reply matching fails. The app uses no ICMP.

## 5. Latency methodology comparison

The number shown as "ping" is the median of 20 `GET __down?bytes=0` round trips minus `cfSpeedEdge + cfSpeedWorker`, with the first (cold) sample excluded when at least five warm samples exist (`CloudflareSpeedTest.measureLatency`). Jitter is the mean absolute difference between consecutive samples. The reasons are in the two tables below.

VERIFIED, build session, 20 samples against speed.cloudflare.com, same minute:

| Method | Median | Note |
|---|---|---|
| Raw HTTP round trip to `__down?bytes=0` | 77.2 ms | Includes Worker time |
| HTTP round trip minus Server-Timing | 52.4 ms | What the app shows as ping |
| cfL4 `min_rtt` (server-measured TCP) | 46.1 ms | Shown separately as TCP RTT |
| curl TCP connect | 34 ms | Includes DNS and process startup |
| ICMP `ping` | 20 ms | Different anycast path |

Conclusion from that study: HTTP minus server time tracks the server's own TCP RTT within about 6 ms and is the same method speed.cloudflare.com uses in the browser. ICMP reads lower because it takes a different path, so it is not the number users compare against the web page.

VERIFIED, research session, 5 samples against speed.cloudflare.com:

| Method | Result |
|---|---|
| ICMP `ping -c 5 -q` | min/avg/max/stddev 27.110/59.117/108.389/33.549 ms |
| curl `time_connect` | 44.7, 47.0, 128.4, 275.9, 55.7 ms |
| cfL4 `min_rtt` | 36.9, 33.0, 30.9, 34.2, 38.7 ms |
| Raw TTFB on `__down?bytes=0` | 213 to 793 ms (`cfSpeedWorker` up to 335 ms) |

VERIFIED, research session, against `1.1.1.1:443`: ICMP 22.9/24.6/27.5 ms (min/avg/max) vs `NWConnection` TCP connect 33.1 to 37.4 ms, a consistent offset of about 10 ms with low variance; curl `time_connect` about 52 ms for the same target. Raw TTFB alone was 5 to 20 times too high in every sample and must never be shown as ping.

## 6. Rejected engines

Cloudflare over URLSession is the primary engine because it needs no install, no binary, no license entanglement (the reference client is MIT), returns the whole Ookla-style tuple (ping, jitter, download, upload, ISP, city, server colo) from one host, streams bytes so progress is live, and works with only outbound network access. `networkQuality` is the secondary engine because its responsiveness figure is genuinely better at showing bufferbloat, but it is slow, undocumented, Apple-CDN-only, and gives no incremental progress.

| Engine | Why rejected | Evidence |
|---|---|---|
| Ookla Speedtest CLI | Proprietary; EULA limits it to "personal, non-commercial use, through a command line interface on a personal computer"; first run needs interactive license acceptance; bundling it in an Apache-2.0 repo is outside the grant. The Homebrew tap formula has no `license` stanza and GitHub reports the license as null, which is not permission. | VERIFIED: only `ookla-speedtest-1.2.0-macosx-universal.tgz` (last-modified 2022-08-09) returns 200; 1.2.1, 1.2.2 and 1.3.0 return 403. The legacy discovery endpoints (`/api/js/servers`, `/speedtest-config.php`) still return 200 but are undocumented and outside the EULA; sivel/speedtest-cli, their main consumer, was archived read-only on 2026-04-30. |
| M-Lab NDT7 | Technically clean and open, but the Acceptable Use Policy says automated clients "should not run more than 4 tests per day" with randomized timing, requires a published GDPR-consistent privacy policy, and publishes every measurement under CC0. Incompatible with an on-demand menu bar button. | VERIFIED: `locate.measurementlab.net/v2/nearest/ndt/ndt7` works and returns 4 servers; its `access_token` JWT expired about 82 s after issue, so locate must be called immediately before each run; the `urls` keys literally contain `ws:///ndt/v7/download`. Possible future opt-in "contribute to open measurement" mode only. |
| Fast.com | No public API. The token must be scraped from `app-<hash>.js`, and both the bundle name and the 32-character token rotate on every Netflix deploy, so a shipped scraper breaks without warning. Download-biased by design. | VERIFIED end to end: `app-0bffe1.js` yielded a token and `api.fast.com/netflix/speedtest/v2` returned `client.isp: "Example ISP"` and target URLs with an `e=` expiry. |
| LibreSpeed | LGPL-3.0 backend; no maintained public server pool (`examples/servers.json` is a 404); pointing a shipped app at volunteers' servers is abuse. | VERIFIED: backend file set is `country_asn.mmdb, empty.php, garbage.php, geoip2.phar, getIP.php, getIP_ipInfo_apikey.php, getIP_util.php`. Worth supporting only as a user-supplied custom backend URL. |

## 7. Where the code deviates from the plan

The code wins in every row.

| Topic | Plan | Code |
|---|---|---|
| `DEVELOPMENT_TEAM` | Certificate CN suffix | Certificate OU, supplied only in a local override. |
| Isolation flag check | `grep` the build log for `-default-isolation=MainActor` | The flag never appears in the log. Proven with a compile probe instead (section 3.6). |
| Latency samples | `URLSessionTaskMetrics` `responseStart - requestStart`, drop samples with `isReusedConnection == false` | Wall-clock around `session.data(for:)`; only the first sample is treated as cold. No metrics delegate on the latency session. |
| ISP fallback chain | `/meta`, then `__down` headers, then `mensura.cdn-apple.com/.well-known/nq`, then "Unknown ISP" | `/meta` only, degrading to `AS<asn>` and then "Unknown ISP" inside `CloudflareMeta.ispDisplayName`. No `ISPResolver`, no `AppleISPLookup`, no 10 minute cache. |
| Loaded latency | Separate session polling `__down?bytes=0` every 500 ms during both phases | `SpeedTestResult.downloadLoadedLatencyMs` / `uploadLoadedLatencyMs` exist but nothing fills them. |
| Byte-cap handling | On 403 with `Content-Length: 1`, halve the chunk once and retry | `ChunkLadder` clamps at 50 MiB so the cap is never requested; `.byteCapExceeded` is classified but the download loop does not halve or retry. |
| `networkQuality` pipes | Drain stdout and stderr concurrently via `FileHandle.bytes` | Both read to end inside `terminationHandler`; the M + 10 s hard deadline is the backstop. |
| Login item | Register on toggle, re-check status at launch | Reconciled every launch against `launchAtLoginWanted` (default true) because BTM reads `.notFound` after a reinstall. |
| DMG filesystem | `-fs HFS+`, staging in `build/dmg` | `-fs APFS`, staging in `mktemp -d` outside iCloud with `ditto --noextattr --noqtn` and `xattr -cr`. |
| Menu bar readout | Two rows, down over up | Single adaptive number: download by default, upload only while upload dominates by 1.3x above a 0.15 Mbps floor, held for 3 s (`ActiveDirectionSelector`). |
| Alert sound | Silent | Silent; `requestAuthorization([.alert])` and `content.sound = nil`. Matches. |

## 8. Sources

Local: `/usr/bin/networkQuality -h`, `-c`, `-v`, `-c -M 10`, `-c -s -M 12`; `codesign -dv --entitlements -` on `networkQuality` and `nettop`; `$SDK/usr/include/net/{if_var.h,if.h,route.h,if_mib.h}`; SwiftUI, SwiftUICore and Network `.swiftinterface` files; AppKit, ServiceManagement and UserNotifications headers; `/System/Library/Sandbox/Profiles/application.sb`; `Swift.xcspec`; `/Applications/CodexBar.app` and `/Applications/NotchHub.app`; the build session's live runs and unit tests.

Remote (all fetched live on 2026-09-04): `speed.cloudflare.com/{meta,__down,__up,cdn-cgi/trace}`; `mensura.cdn-apple.com/.well-known/nq` and `/api/v1/gm/{small,large,slurp}`; `locate.measurementlab.net/v2/nearest/ndt/ndt7`; `raw.githubusercontent.com/teamookla/homebrew-speedtest/master/speedtest.rb`; `install.speedtest.net/app/cli/ookla-speedtest-1.2.0-macosx-universal.tgz` (HEAD); `api.fast.com/netflix/speedtest/v2`; `api.github.com/repos/librespeed/speedtest/contents/backend`; `raw.githubusercontent.com/exelban/stats/master/Modules/Net/readers.swift`.

Documents: Apple TN3179 (local network privacy); Apple Energy Efficiency Guide for Mac Apps (App Nap, timer coalescing); RFC 9097; `m-lab/ndt-server` `spec/ndt7-protocol.md`; M-Lab AUP and privacy policy; Ookla EULA; `@cloudflare/speedtest` package metadata; Feedback Assistant mirror issues 328, 329, 330, 331, 383; Apple Forums threads 123873, 724249, 649583, 679326, 726565, 792453, 814226; notifee issue 260; orchetect/MenuBarExtraAccess README; sjhooper/TahoeMenuDemo README (its API-status claims are wrong, see 3.2).
