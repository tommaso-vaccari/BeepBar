# Bounded metadata reception validation (#102)

Date: 2026-10-09. Base dev: `ac68333265a68b3f1e01e7f0958c3aae31cc7850`.
Implementation: `3d94bdab0e20896fae63318c30f782afb2267e3c`.
Frozen released main: `3ce0ba02c10dcf51836057f7119ba0e78da3c6e4`.
This is a proposal for dev, not integrated or released work.

## Contract and decision

The site-info, courses and course-contents callers still use inclusive 1/2/4 MiB caps.
A per-task URLSession data delegate validates the response before allowing its body,
then checks the decompressed chunks before appending. A rejected chunk is never retained;
the task is cancelled immediately. Oversized Content-Length can reject earlier but never
substitutes for counting delivered bytes. The injected session remains the transport,
including its URLProtocols, credentials and redirect/authentication delegates.
The default session supplies background chunk callbacks, with no per-byte/main-actor work.

The sync specification's file preservation and error recovery behavior is unchanged.
Overruns remain responseTooLarge, explicit cancellation remains CancellationError,
and transport/status/content-type/Moodle error classifications remain covered by tests.
No anomalous response was sent to a real service.

## Regression and edge cases

On the base production code, `MetadataResponseTests/stopsOversizedResponseWhileReceiving`
fails all five header cases: missing, falsely low, exactly at the cap, invalid and numeric
overflow. Each receives the full 16 MiB instead of stopping within 1 MiB + 64 KiB.
On the candidate, the same acceptance test passes. The fixture lazily creates 16 KiB chunks
on a background queue at 1 ms intervals; it never preallocates the advertised body.
The stop handoff uses an event group, with a one-second watchdog only for a missing callback.
The final acceptance fixture holds its transport window after the decisive chunk; a two-second
watchdog lets the broken base proceed to the entire body. This prevents arbitrary URLProtocol
queue growth under parallel tests from being mistaken for the receiver accumulator.

Other tests cover valid JSON exactly at every caller's cap and one byte over, early excessive
header rejection, status/content-type precedence, offline/timeout/connection-loss mapping,
user and pre-start cancellation, existing invalid-token behavior, a real loopback gzip
response expanding above the cap, the standard session's redirect refusal, and forwarding
an HTTP authentication challenge to an injected delegate that explicitly cancels it.
The loopback server and test token are synthetic.

## Memory probe

Apple Silicon Mac17,3, 24 GiB RAM, macOS 27.0.1 (26A434), Swift 6.4 / macOS SDK 27,
Release arm64, battery power (19% at setup). Five fresh test processes per body size/ref.
The initial 16 MiB base run established the probe before the five recorded samples.
RSS is this test process's `getrusage(RUSAGE_SELF).ru_maxrss`, reported in bytes on Darwin;
it excludes the compiler process. Other tasks were asked to suspend builds/tests during sampling; overlap cannot be independently
ruled out. No timing conclusion is drawn from these samples.
The probe used the implementation commit above, before the final fixture transport-window
improvement. The base and candidate use the same lazy payload, chunk size, pacing and fake token;
the candidate additionally waits for URLProtocol.stopLoading before reporting final sent bytes.
This is a resource-bound demonstration, not a latency, CPU, UI or AC-powered benchmark claim.

| Advertised body | Base median peak RSS (B) | Candidate median peak RSS (B) | Absolute delta (B) | Delta | Base delivered (B) | Candidate delivered (B) |
|---|---:|---:|---:|---:|---:|---:|
| 16 MiB | 48218112 | 15351808 | -32866304 | -68.16% | 16777216 | 1064960 |
| 128 MiB | 284557312 | 15319040 | -269238272 | -94.62% | 134217728 | 1064960 |

Increasing the synthetic body eightfold leaves the candidate peak stable, and every candidate
run receives exactly 1 MiB + one 16 KiB chunk. The accumulator retains at most 1 MiB;
the rejected transport chunk is not appended. The fixture acceptance allows at most four extra
chunks for the asynchronous transport stop handoff. This observation does not specify a universal
CFNetwork buffer size or bound an adversarial custom URLProtocol's own allocation/queue.

Raw peak RSS samples, in bytes (runs 1–5):

- base, 16 MiB: 48201728, 48218112, 48250880, 48267264, 48152576.
- base, 128 MiB: 284622848, 284540928, 284573696, 284540928, 284557312.
- candidate, 16 MiB: 15269888, 15351808, 15286272, 15368192, 15384576.
- candidate, 128 MiB: 15335424, 15335424, 15319040, 15269888, 15269888.

On a configured Xcode toolchain, reproduce the probe using the committed test with each
production ref, overlaying only the same synthetic test fixture for references predating it:

```sh
BEEPBAR_METADATA_PROBE_MIB=16 swift test -c release --filter MetadataResponseTests/memoryProbe
BEEPBAR_METADATA_PROBE_MIB=128 swift test -c release --filter MetadataResponseTests/memoryProbe
```

Repeat in five fresh processes per size. Do not measure a compiler together with the test:
compile first, then use `swift test --skip-build -c release --filter MetadataResponseTests/memoryProbe`.

## Verification gates

Xcode 27.0 (27A266a) became available after the initial probe. Standard repository gates
passed on `819462da4400228346b81d7c613344b412da2802`:

- `swift test`: 368 Core + 27 Benchmark + 257 App Swift Testing tests and 14 XCTest tests
  passed (666 total), including metadata/API, sync failures, recordings and app behavior.
- `xcodebuild -project Beepbar.xcodeproj -target Beepbar -configuration Release build
  CODE_SIGNING_ALLOWED=NO`: BUILD SUCCEEDED. The normal app was not launched or installed.

The exact final documentation commit and its gate rerun are recorded in the issue before
independent review. Production code is unchanged from the implementation commit used by
this memory experiment; the later test improvement only bounds the synthetic transport window.

Initial validation had only Command Line Tools, without the necessary SwiftUI/Testing macros
and XCTest. An external temporary package read the exact repository Sources/Tests and included
CSQLite, BeepbarCore, BeepbarBenchmarkKit and their test targets only. That fallback used SDK27,
native SwiftPM, `--disable-xctest`, and the CLT Testing.framework compiler/linker paths; it changed
no production source or repository manifest. All 395 Core/Benchmark tests passed there,
including the five-case final controlled mutation (red without the fix, green restored).
Its Release arm64 build supplied the isolated memory-probe binaries. Those earlier environment
failures are resolved for the standard test/build gates by the installed Xcode toolchain.

The standard benchmark `scripts/benchmark.sh compare --main origin/main --base-dev origin/dev
--candidate HEAD ...` remains **unmeasured** at this checkpoint. The memory experiment was on
battery, and no coordinated AC-powered reference comparison was run. Both standard base-dev
→ HEAD and cumulative main → HEAD comparisons remain unmeasured, including normal-response
throughput, CPU and UI occupancy. The table above is the separate synthetic memory experiment
only. No benchmark was rerun while the other tasks were running their verification.
Independent review and online CI are recorded below for the resumed PR; the earlier green
CI on `096570b` did not cover its missing cancellation handoff regression.

## PR #127 cancellation handoff follow-up

The owner’s independent review of `096570b` identified a P1: Foundation can complete a
cancelled suspended URLSession task before the checked continuation is installed. The old
callback discarded that terminal result, so the later consumer could remain suspended.
[PR #127](https://github.com/tommaso-vaccari/BeepBar/pull/127) remains open against `dev`.
Merge `f23b8ee` incorporates current dev `713033cb164e549dd1ba652d19bb559ec68d8146`.

Fix `1e65515e245c200e31f61fa0789dff5649761aed` retains the first terminal Result under the same
lock as consumer installation. Installation either receives that stored result or registers
one continuation; later callbacks cannot replace it. The one-consumer precondition states the
per-request lifetime. Continuation resume and transport start/cancellation happen outside the
lock, preventing callback reentrancy from deadlocking. Reception bounds and rejection precedence
remain unchanged. A completion that wins before installation prevents the transport from starting.

`MetadataCompletionTests/terminalCancellationBeforeContinuationInstallationIsRetained` directly
delivers the valid terminal-cancellation callback before installing the consumer through the
same `receive` path used by `run`. That order is deterministic, without a sleep; the two-second
watchdog only detects a missing completion and replays a callback to release a broken mutant.
The lower-level bridge delivers URLError.cancelled; the existing public-client cancellation tests
verify its conversion to CancellationError. Other bridge fixtures cover early/installed success,
a duplicate error after success, and thirty concurrent success/cancellation callback races.

The controlled mutation restored the `096570b` continuation installation and completion behavior
while retaining the extraction seam. The test compiled and failed with two issues: a completed
transport attempted to start and its first cancellation result was lost. Restored code passed
all ten metadata-response/bridge tests. Exact logs: `/tmp/beepbar-pr127-mutation-red.log` and
`/tmp/beepbar-pr127-focused-green.log`; commands were `swift test --filter
MetadataResponseTests/terminalCancellationBeforeContinuationInstallationIsRetained` (mutant)
and `swift test --filter MetadataResponseTests` (restored, before the portable suite split).

On clean `1e65515`, standard `swift test` passed **694 tests** (371 Core, 27 Benchmark,
282 App Swift Testing plus 14 XCTest) and the unsigned Release target build succeeded.
Logs: `/tmp/beepbar-pr127-full-1e65515.log` and `/tmp/beepbar-pr127-release-1e65515.log`.
The normal app was never launched or installed. A fresh independent review approved the
completion protocol and identified one integration finding: Darwin-only tests conflicted with
Linux Core support newly landed in dev. Follow-up `d4c0012` uses conditional imports, retains
transport-independent bridge tests on Linux, and skips the custom-URLProtocol suite in Linux’s
existing skip policy. The socket suite and byte-valued RSS probe exercise Apple CFNetwork/Darwin
and compile only there. Focused macOS metadata tests passed after this adjustment.
Final independent approval and exact pushed-HEAD gates are recorded in the PR/issue checkpoint.
