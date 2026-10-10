# D07 isolated UI tooling — #95

Branch: `perf/isolated-ui-harness`, base `origin/dev` `ac68333`.
Verified implementation: `fe47bb571cd3d05ac4c8013df8c05e6b849bb259`.
The earlier candidate `281cb94` failed the opt-in fixture compilation; `0666707` corrected
its continuation type and passed the initial gates. Independent review of `a1496b2` found
three P2 issues: repeated key-window events overwrote the first timestamp, power changes
were not checked after recording, and trace success did not prove usable artifacts.
`f32a07e` fixed these with regressions and explicit CPU/signpost exports; `fe47bb5` corrected
the first-key test's Swift Testing expression. Results below refer to this corrected code,
except the historical functional batch explicitly identified below.

## Local code gates

Host: Apple M5, `Mac17,3`, 24 GiB RAM, macOS 27.0.1 (`26A434`), Xcode 27.0 (`27A266a`),
Developer directory `/Applications/Xcode.app/Contents/Developer`, xctrace 27.0.

| Gate | Result | Retained local evidence |
|---|---|---|
| `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_ui_benchmark.py` | **13 PASS** including post-run power and missing/unusable trace safeguards | `/tmp/issue95-python-judge-fixes.log` |
| `swift test --filter UIFixtureTests` on the restored disposable copy | **8 PASS**, also included in the full suite | `/tmp/issue95-offline-mutation-fe47bb5-restored-green.log` |
| `swift test` on `fe47bb5` | 358 Core + 27 Benchmark + 265 App Swift Testing + 14 XCTest = **664 PASS**, zero failures | `/tmp/issue95-full-judge-fixes.log` |
| Ordinary Xcode Release app build, signing disabled | **BUILD SUCCEEDED** on `fe47bb5` | `/tmp/issue95-release-judge-fixes.log` |
| Opt-in fixture Release arm64 build | **BUILD SUCCEEDED** on `fe47bb5` (14.41 s); Mach-O arm64; identity `beepbar-isolated-ui-fixture-v1` | `/tmp/issue95-fixture-build-judge-fixes.log` |
| Offline and first-key mutations in a disposable source copy | Compiled **RED**, two tests with three issues; restored original **8 GREEN** | `/tmp/issue95-offline-mutation-fe47bb5.log`, restored log above |

The standard Release command was:

```sh
xcodebuild -project Beepbar.xcodeproj -target Beepbar -configuration Release \
  -clonedSourcePackagesDirPath build/SourcePackages build CODE_SIGNING_ALLOWED=NO
```

The dedicated fixture was compiled with:

```sh
swift build --disable-sandbox --scratch-path /tmp/BeepbarUICompile-281cb94 \
  -c release --arch arm64 --product Beepbar -Xswiftc -DDEBUG \
  -Xswiftc -DUI_PERFORMANCE_HARNESS
```

The scratch directory's name records its first attempt; the latest successful build above
compiled `fe47bb5`. Identity verification uses `--harness-identity`, which
returns before constructing `NSApplication`. No ordinary app, installed app, signing identity,
real account or production data directory was launched or changed by these gates.

To reproduce the offline sensitivity check, export `fe47bb5` with `git archive` into a fresh owned
temporary directory, change exactly the fixture's
`if account.offline { throw URLError(.notConnectedToInternet) }` to
`if false && account.offline { throw URLError(.notConnectedToInternet) }`, then run:

```sh
swift test --filter offlineRefreshRetainsKnownCoursesAndReportsFailure
```

It must compile and fail because `courseLoadError` is nil. Keep all URLProtocol injection,
unknown-host/token rejection and synthetic credentials unchanged. Run the unmodified fixture
suite for the green side; never remove the network interception as a mutation. A second
mutation changes `UIFixtureWindowTiming.becameKey`'s `guard keyMilliseconds == nil` to
`if false`; `firstKeyTimestampSurvivesLaterFocusChanges` must then fail because later focus
changes overwrite the first timestamp. The recorded combined mutation used a disposable
copy, restored both guards for the green side, and deleted only that owned copy after logs
were retained.

## Functional UI smoke, separate from measurements

Historical batch on `0666707`, before the review fixes: all twelve short scenarios produced
valid reports: cold/warm/offline, 100/500 courses,
reopen during a genuine held sync, expanded Activity 1k/15k, Recordings 1k/5k,
progress burst, and ten open/sync/close cycles. Each scenario was run once in a fresh process
inside an owned temporary bundle with a unique bundle ID, the renamed fixture executable,
and a separately owned temporary fixture directory. Bundle/data were removed afterwards.
The reports verified key-window and populated-content callbacks, exact corpus and cycle
counts, and nominal end thermal state. This is a functional entry-point/content check.

Evidence: `/tmp/issue95-functional-scenarios-0666707/` contains each raw report and process log;
`interpretation.txt` marks the batch as functional-only. There is also a first 100-course smoke
at `/tmp/issue95-functional-smoke-0666707/`. During Activity 15k construction, a process snapshot
showed substantial CPU/RSS use. That is retained as a qualitative finding for D11, not an AC
latency/memory benchmark, measured benefit, population p95 or responsiveness claim.

### Trace decoder and current-code probe

A historical functional trace on `0666707` with Time Profiler and the explicit `os_signpost`
instrument passed the new decoder: 233 fixture main-thread samples with stacks and all four
required course-window UI markers. Evidence is local at
`/tmp/issue95-functional-signposts-0666707/`; it is not a comparable measurement series.

On `fe47bb5`, one isolated `launch-warm` process completed both opens successfully and emitted
a report. The evidence validator **rejected the sample**: `thermalState = 1` (fair), rather
than required nominal `0`; Low Power Mode was off. It ran on battery and cannot be accepted
as an AC benchmark. No timing or memory budget pass is claimed for it. Its trace nevertheless
passed the artifact decoder: 491 CPU samples, 431 fixture main-thread samples with stacks,
`ui.iconReady` once, and `ui.fixtureOpen`, `ui.windowKey`, `ui.firstCourseContent` twice each.
Evidence: `/tmp/issue95-functional-warm-fe47bb5/` (the raw report is named `courses-100.json`,
while its scenario field is correctly `launch-warm`). Artifact decoding proves retained,
readable evidence; it does not override the rejected environment metadata.

Raw `.trace` files can contain device names/identifiers and stay local. Exported TOC metadata
is sanitized by the driver before use in the evidence summary. Synthetic workload reports
contain no real account data. No raw trace is committed or attached to the PR.

## Measurement blocker and remaining acceptance

At preflight on 2026-10-10 15:10 UTC, `pmset -g batt` reported **Battery Power**, 97%,
discharging. The driver requires AC and refuses to start a measurement series in that state.
The functional checks above do not substitute for the following unmeasured gates:

- At least five comparable Release arm64 samples with main-thread traces for every UI scenario.
- A 30-minute unprofiled idle observation with CPU/writes/wakeups/request accounting.
- Comparable stabilized memory after ten open/sync/close cycles.
- Independent trace interpretation, scrolling/actions and the 16ms frame/main-thread budget.
- Full launch-to-icon/bootstrap evidence. Current icon timing covers construction after synthetic
  dependency preparation; cold UI timing covers the first fixture window, not the production
  credential/bootstrap/migration or process-loader path.
- Persisted cold offline course restoration remains D10; the current offline scenario validates
  known synthetic model retention during a failed refresh.

No base-dev → HEAD or main → HEAD UI benefit is claimed. No Time Profiler series, idle result,
reliable p95 or completed D07 acceptance is claimed. The tooling can be reviewed independently;
**#95 remains open** and any partial tooling PR uses `Refs #95`, not `Closes #95`.

After AC is connected and other builds/downloads are quiet, run the documented
[single command](../ui-benchmarks.md#single-command) on the reviewed source, retain raw traces,
check budgets and record negative findings. Five samples yield an unstable nearest-rank p95;
expand samples before a reliable tail claim. Main-thread traces and manual interaction are
required because SwiftUI `onAppear` proves hierarchy readiness, not compositor presentation.

CPU resource counters use Mach-time conversion. The Apple kernel assigns rusage CPU fields from
task power times, whose values are `rm_time_mach`; see
[Apple XNU rusage implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c)
and [task power implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c).
