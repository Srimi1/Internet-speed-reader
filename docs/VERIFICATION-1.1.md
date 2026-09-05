# Version 1.1.0 verification

This public summary records completed checks and remaining limits for the 1.1.0
implementation. Detailed machine logs, network metadata, local history, exact session
times and backup locations are kept outside the repository.

## Automated checks

The original 75 tests passed before changes. The final integrated suite passed all
**125 tests**, with zero failures or skips. A universal Release build for arm64 and
x86_64 also passed.

Added coverage includes delayed and missing counters, recovery, power policy,
interface changes, upload hysteresis and control traffic, sleep during a test,
validated transfer accounting, partial and oversized responses, transport failures,
upload acknowledgements, deadlines, concurrent byte budgets, slow links, irregular
timing and stalls, run ownership/cooldowns, cancellation, Apple subprocess behavior,
and older history decoding. Network metadata fixtures use synthetic values.

## Installed-app checks

| Check | Result |
|---|---|
| Automatic launch monitoring | Fresh readings began with the panel closed; no Go click was required. |
| Default cadence in Low Power Mode | Approximately one-second readings continued independently of the panel. |
| Explicit battery-saving cadence | Fresh readings spanning roughly 5.02–5.25 seconds continued with the panel closed. This reproduces the interval that v1.0 incorrectly rejected. |
| Return to default cadence | Restoring Always returned to approximately one-second readings. |
| Settings | Both the panel command and Cmd+, opened the native Settings window. |
| Idle | Consecutive measured zero-traffic samples were recorded. Exact menu-bar text was not independently photographed. |
| Direction selection | During an Apple load with the panel closed, outgoing control traffic remained filtered; sustained upload selected upload and low activity restored download. State changes were recorded by the renderer's selector. |
| Faster simultaneous download | Upload priority is covered by deterministic tests; that precise condition was not established in the physical comparison. |
| Reconnection | After Wi-Fi was switched off and restored, fresh samples resumed without Go or opening the panel during recovery. |
| Preferences and history | Existing records and settings were preserved during installation; legacy results retained method labels. |
| Login registration | Registration reported enabled; a new login session has not yet verified automatic launch. |
| System sleep | Inconclusive: the attempted physical check established display sleep and recovery from a sampling gap, but not confirmed system sleep/wake. Deterministic lifecycle tests passed. |

The v1.0 defect was a fixed five-second rejection threshold combined with five-second
sampling: ordinary scheduling delay made valid intervals exceed that threshold. The
new threshold is `max(5 seconds, 3 × expected interval)`, using actual elapsed time.

## Independent counter comparison

An independent `netstat` sampler and the app's raw interface-counter samples were
compared over matching intervals during background traffic, a successful download
and a successful upload. Fifty matched intervals showed close aggregate agreement.
This checks acquisition and elapsed-time arithmetic for the same counter domain.
It does not establish per-second precision, ISP capacity, application attribution,
payload throughput, or agreement with Ookla. Interpolation, burst timing and sample
boundaries limit the comparison; the short upload only partially overlapped the
reference window. Personal network measurements and endpoints are not published.

## Manual capacity tests

- Cloudflare Go requests were refused with HTTP 403 during the download phase,
  including a 16 MiB request after metadata, latency and smaller requests succeeded.
  The cause is unproven. The app displayed the refusal prominently, saved no invalid
  result and automatically re-enabled Go after its countdown. HTTP 429 retains a
  separate rate-limit cooldown.
- **Three successful Cloudflare runs were not completed.** Failed attempts are not
  capacity measurements or evidence of repeatability.
- Apple Deep Test completed through the native panel. A separate Apple command-line
  reference also completed. The final native run continued after closing the panel
  and saved a validated result. Different runs selected different endpoints and
  background traffic continued, so their variation is not a controlled comparison.
- Ookla browser testing was blocked by the browser security policy. No workaround
  was attempted and no Ookla agreement is claimed.

## Packaging and rollback

The local 1.1.0 development bundle was installed, and the installed signature and disk
image integrity checks passed. Preferences, history and the previous app were backed
up privately before replacement. That original development image contains signing
identity metadata and must not be uploaded as a privacy-preserving public artifact.
A separate universal public image was rebuilt with ad-hoc signatures and no personal
certificate. Its disk-image integrity and signatures passed verification. The
[release notes](releases/1.1.0.md) identify the artifact and checksum. The app is not notarized.

To roll back a local installation, quit the app, restore the previously saved app
bundle and reopen it. Leave existing preferences and history in place unless recovery
of those files is also necessary. Never publish the backup or the app's data folder.

## Remaining verification

- Three successful sequential Cloudflare Go tests when the provider permits them.
- Confirmed physical system sleep/wake recovery.
- Launch at login during a new login session.
- First launch and permission behavior on a separate Mac.

These limits remain visible because passing tests and local installation alone do
not establish every real-world behavior.
