# Roadmap

**2026-09-05 update:** This roadmap preserves the v1.0 backlog and limitations. Its earlier Cloudflare byte-cap and HTTP 403 assumptions are superseded: v1.1 received HTTP 403 for a 16 MiB download, whose cause remains unknown. The 50 MiB ceiling is a conservative client choice, not a published endpoint limit. Only HTTP 429 triggers the 15-minute backoff; HTTP 403 is an explicit refusal. See [current verification](VERIFICATION-1.1.md).

What the approved plan (`docs/PLAN.md`) still leaves open after v1.0.0, what the shipped build cannot do, and the next things worth doing. Nothing here is a commitment or a date. Every item was checked against the code before being listed.

## Plan features not yet shipped

- **Loaded latency.** Run a zero-byte request every 500 ms on its own session during the download and upload phases and store the per-direction medians in the `downloadLoadedLatencyMs` and `uploadLoadedLatencyMs` fields that `SpeedTestResult` already has.
- **ISP fallback chain.** After `/meta` fails, read `asn`, `city` and `colo` from a `__down` response, then `apple-client-asn-company` from `https://mensura.cdn-apple.com/.well-known/nq`, before falling back to "Unknown ISP". Show the colo that served the download rather than the one `/meta` reports.
- **Wire the inert settings.** `notifyOnDrop`, `notifyOnRestore`, `notifyAfterSeconds`, `minimumOutageSeconds`, `refreshPolicy`, `confirmOnMetered` and `appleMaxSeconds` are shown in Settings but nothing reads them. Pass them into `ConnectivityStateMachine.Config`, `OutageLedger`, `LiveThroughputMonitor.setCadence` and `NetworkQualityRunner.run(maxSeconds:)`, and check the two notify flags in `AppCoordinator.handle(_:engine:)`.
- **Metered and Low Power confirmation.** Before a test, check `PathSnapshot.isExpensive`, `isConstrained` and `ProcessInfo.isLowPowerModeEnabled`, and show a sheet with the estimate from `AppSettings.estimatedBytesPerTest`. Also refuse to start while the state is `captivePortal` or `offline`.
- **Reopen the panel on finish.** Call `StatusItemController.reopenPanelForResult()` when `SpeedTestController` finishes and `reopenPanelOnFinish` is on. Both halves exist; only the call is missing.
- **Notification actions.** Assign `NotificationService.onRunTestRequested` and `onShowLogRequested` so the "Run Speed Test" and "Show Outage Log" buttons on the outage banner do something.
- **Rate-limit escalation.** Replace the single 15 minute `blockedUntil` with the planned 15 minute, 1 hour, 6 hour sequence.
- **Path change abort.** Compare `PathSnapshot.generation` at test start and during the run, and throw `SpeedTestError.networkChanged` when it moves.
- **Interface override.** A picker in the Network tab that binds the live meter and the `-I` flag of `networkQuality`. `URLSession` cannot bind to an interface, so the Cloudflare test would stay on the default route.
- **Export.** Write `speedtests.json` and `outages.json` out as CSV or JSON from the panel.
- **Result details.** A disclosure under the result tiles showing protocol, streams, mean, peak, server-confirmed upload bytes, TCP RTT and data used. The fields are already stored.
- **Testability.** Inject the session configuration into `CloudflareSpeedTest` and add a `URLProtocol` stub so the two-stream aggregation test and the prober hang test from the plan can exist without a network.
- **Liquid Glass.** A glass panel background under `#available(macOS 26, *)`, with the plain material kept for macOS 14 and 15.

## Known limitations

- **Not notarised.** The DMG is signed with an Apple Development certificate. On any other Mac the first launch is blocked until the user opens the app from the right-click menu or strips the quarantine attribute. Removing this needs a paid Developer ID certificate and notarisation.
- **The certificate expires.** Apple Development certificates last about a year. When it lapses, the fallback is renewal or ad-hoc signing with hardened runtime off, which re-prompts for notifications after every rebuild.
- **Focus modes hide banners.** Notifications use `interruptionLevel = .active` because `.timeSensitive` needs an Apple-granted entitlement. Any Focus mode can hide the drop and restore banners. The red menu bar is the only guaranteed signal, and the Alerts tab says so.
- **Menu bar overflow on notched Macs.** macOS silently hides a wide status item when the bar is crowded and offers no API to prevent it. The adaptive, one-line and dot-only layouts reduce the width; there is no way to force visibility.
- **Menu bar position.** An app cannot place its item next to the clock. The user must Command-drag it; `autosaveName` keeps the position.
- **The popover dismisses mid-test.** The popover is transient, so a click elsewhere closes it. The test keeps running and the dot stays blue, but the panel does not reopen by itself (see above). A non-activating floating panel is the planned replacement.
- **Live and test numbers differ.** The menu bar reads kernel `if_data64` counters for one interface and every app on the Mac, so it runs above the test's payload figure. Measured overhead during the build was 9.6 percent on a 50 MiB download. The panel footnote and the README explain this.
- **Cloudflare is not a documented API.** The `Referer` gate on `/meta`, the 50 MiB `__down` cap and HTTP/1.1-only negotiation were all observed live and can change silently. The engine validates every response and labels a bad one as an interception rather than a number.
- **ICMP ping reads lower than the app's ping.** ICMP to speed.cloudflare.com measured 20 ms against 46 to 52 ms over HTTP and TCP, because it takes a different anycast path. The app's number is comparable to the web speed test, not to `ping`.
- **VPN handling is untested.** `ActiveInterfaceSelector` prefers a physical interface and falls back to a tunnel, and the header labels tunnel payload, but no real VPN was exercised during the build.
- **Cadence is fixed at launch.** `PowerPolicy` is evaluated once. Plugging in or unplugging after launch does not change the sampling interval until the next launch.

## Next steps

- Finish the wiring gaps first: the inert settings, `reopenPanelForResult()` and the notification action handlers are small changes with existing halves in the code.
- Run the verification items that were not recorded during the build: an overnight soak with flat memory, a real VPN connect and disconnect, an `/etc/hosts` blackhole of both probe hosts, and a captive portal.
- Observe power source changes and re-apply `PowerPolicy.currentCadence()` when they happen.
- Replace the transient popover with a non-activating floating panel so a running test stays visible.
- Add the `URLProtocol` stub and the two missing tests before touching the engine again.
- Consider a Developer ID certificate and notarisation once the app is shared beyond the author's Mac.
