# Internet Speed Reader

A menu bar app for macOS that tells you what your internet is doing right now, and
tells you the moment it stops.

It sits in the top-right of the menu bar showing live download and upload throughput
with a status dot. When the connection drops the dot and the numbers turn red and a
notification arrives; when it comes back another notification says how long you were
out. Click the item to run an Ookla-style speed test: ping, jitter, download, upload,
your ISP and the server that answered.

Everything runs locally. There is no account, no telemetry, and nothing to install
beyond the app itself.

## Install

Download the disk image from [Releases](https://github.com/Srimi1/Internet-speed-reader/releases),
open it, and drag the app onto the Applications folder.

The build is signed for development but is not notarised by Apple, so the first launch
on another Mac is blocked. Right-click the app in Applications and choose Open, then
Open again. You only need to do this once. The equivalent from Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/InternetSpeedReader.app
```

Building from source instead:

```bash
git clone https://github.com/Srimi1/Internet-speed-reader.git
cd Internet-speed-reader && ./scripts/install.sh
```

That needs Xcode and XcodeGen (`brew install xcodegen`). To produce a disk image, run
`./scripts/make-dmg.sh`.

## What the numbers mean

The two figures in the menu bar and the two in a speed test measure different things,
and they will not agree. That is expected, not a bug.

| | Menu bar | Speed test |
|---|---|---|
| Source | Kernel interface counters | Bytes this app transferred |
| Covers | Every app on your Mac | Only the test |
| Layer | Link layer, including TCP, TLS and retransmits | Payload only |
| Effect | Reads roughly 10 to 17 percent higher | The comparable number |

So the menu bar answers "is my connection busy right now", and a speed test answers
"how fast is this connection". Use the second one when comparing against other tools.

Speed tests measure against Cloudflare's public endpoints, the same infrastructure
behind speed.cloudflare.com, so you can cross-check a result in a browser. The Apple
deep test in the right-click menu runs the system's own `networkQuality` tool instead,
which reports responsiveness under load, a figure an idle ping cannot capture. Its
results are kept in their own column because it measures different servers by a
different method.

## Outage detection

A path that goes down is not proof the internet is gone, and a path that is up is not
proof that it works: a captive portal satisfies the network path perfectly while
blocking everything. So the app actively probes, and it is deliberately slow to cry
wolf and quick to forgive:

- Two consecutive failed probes confirm an outage; a single success clears it.
- The outage is stamped at the first failure, not the confirming one, so the duration
  you read is honest.
- Losing the network path waits out a three second debounce, otherwise roaming between
  access points would flash red several times a day.
- Closing the lid, switching networks and waking from sleep open a grace window that
  suppresses notifications. The outage log still records everything.
- Outages shorter than three seconds are treated as noise and never logged.
- A portal is reported as "sign-in required" rather than as an outage.

Notifications use the standard alert level, so a Focus mode can hide them. The red menu
bar is the signal that always shows.

## Menu bar position

macOS does not let an app place itself next to the clock. Hold Command and drag the
item to where you want it, and it stays there. On a Mac with a notch, the two-line
layout can be pushed into the hidden overflow area when the bar is crowded; the
one-line and dot-only layouts in Settings are there for that case.

## Settings

Launch at login, bar layout and units, how long an outage must last before it notifies,
how many streams a test uses and for how long, a data-saver mode, and an estimate of
how much data one test moves. Roughly: a ten second test on a 200 Mbps link moves about
250 MB, so the app asks before testing on a metered connection.

## Development

```bash
xcodegen generate                    # regenerate the Xcode project
xcodebuild -scheme InternetSpeedReader -destination 'platform=macOS' test
./scripts/install.sh                 # build Release and install to /Applications
./scripts/make-dmg.sh                # build dist/InternetSpeedReader-<version>.dmg
./scripts/uninstall.sh               # remove the app and its data
```

The code splits in two. `SpeedCore` is a plain library with no UI that holds the
measurement and state logic; it is nonisolated and fully unit tested without a network.
The app target holds AppKit and SwiftUI and runs on the main actor. The unit test bundle
depends only on `SpeedCore` and has no test host, so running tests never launches the
menu bar agent.

Notes for anyone changing this code:

- Interface counters come from `NET_RT_IFLIST2` and the 64-bit `if_data64` struct. The
  32-bit counters behind `getifaddrs` wrap every 4.3 GB and had already wrapped on the
  machine this was developed on.
- Throughput is the sum of all streams counted into one shared ledger and divided by
  measured elapsed time. Averaging per-request rates under-reports by roughly the stream
  count.
- Server processing time from `Server-Timing` is subtracted from latency only, never
  from throughput.
- A download response that is not `application/octet-stream` of exactly the requested
  length aborts the test, so an intercepting portal can never be measured as speed.

## Uninstall

Turn off "Launch at login" in Settings first, then run `./scripts/uninstall.sh`, which
removes the app along with its preferences, history and outage log.

## Licence

Apache-2.0. Speed tests use Cloudflare's public endpoints and Apple's `networkQuality`;
this project is not affiliated with, or endorsed by, either company or with Ookla.
