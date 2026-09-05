# Historical version 1.0 verification

This is an archived, privacy-preserving summary of the original 1.0 release.
Use [version 1.1 verification](VERIFICATION-1.1.md) for current results and remaining
checks. The original session's personal network details, signing identity, local
paths and raw logs are intentionally excluded from the public repository.

## Completed checks

- A native Swift menu bar application was built and installed on an Apple silicon
  Mac. Its universal Release build and original library test suite passed.
- The live meter read 64-bit interface counters; manual comparison exercised a
  download and idle traffic. These were observations on one connection, not a
  universal accuracy guarantee.
- An end-to-end Cloudflare test returned download/upload/latency measurements and
  server acknowledgement of uploaded bytes. Its original aggregation method is now
  identified as the earlier method in history.
- Login registration was reconciled successfully after repeated local reinstalls.
- A disk image was staged outside cloud-synced storage, stripped of problematic
  extended attributes and verified for integrity.

## Defects found during development

A task-scoped URLSession delegate did not provide expected incremental download
callbacks; a session-level data delegate fixed the zero-download result. Cloud file
provider metadata broke staged-app signature verification, so packaging moved to a
temporary directory outside the checkout. A local signing configuration also confused
a certificate's common-name suffix with its team OU; personal signing settings must
now stay outside version control.

The original release still had behavior superseded by 1.1, including a fixed
five-second sampling rejection threshold, download-dominance direction selection,
optimistic transfer accounting and ambiguous HTTP 403 classification. Historical
successes do not establish that those paths were correct.

## Original verification gaps

No confirmed system sleep/wake or overnight soak, real next-login launch, VPN/captive
portal session, second-Mac first launch, notification permission persistence,
independent Ookla comparison or live interception test was recorded for version 1.0.
Some later checks are covered by the current report; unrecorded checks must not be
assumed to have passed.

## Reproducing current checks

Follow [CONTRIBUTING.md](../CONTRIBUTING.md) for local build/test setup and
[ARCHITECTURE.md](ARCHITECTURE.md) for runtime contracts. Run the core suite with a
local DerivedData directory, install the app as a bundle, and exercise monitoring
with the panel closed before checking Go/Stop, recovery, settings and login behavior.
Keep raw logs, app history, screenshots containing personal details and signing
material outside the repository. Report only sanitized observations and clearly
separate measured behavior from expected behavior.
