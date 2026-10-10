# D07 isolated UI tooling — #95

Branch: `perf/isolated-ui-harness`, base `origin/dev` `ac68333`.
Verified implementation: `0666707962ba386c075a9087e062217dee95701b`.
The earlier candidate `281cb94` passed ordinary app tests/build but failed the opt-in fixture
compilation: an explicitly typed `CheckedContinuation<Void, Error>` fixed its inference failure.
The final fixture report is encode-only. Results below refer to the corrected implementation.

## Local code gates

Host: Apple M5, `Mac17,3`, 24 GiB RAM, macOS 27.0.1 (`26A434`), Xcode 27.0 (`27A266a`),
Developer directory `/Applications/Xcode.app/Contents/Developer`, xctrace 27.0.

| Gate | Result | Retained local evidence |
|---|---|---|
| `PYTHONDONTWRITEBYTECODE=1 python3 scripts/test_ui_benchmark.py` | 8 Python evidence safeguards PASS | Test stdout; no app/network/build |
| `swift test --filter UIFixtureTests` | 7 fixture tests PASS; included again in the full final suite | `/tmp/issue95-targeted-second.log` |
| `swift test` on `0666707` | 358 Core + 27 Benchmark + 264 App Swift Testing + 14 XCTest = **663 PASS**, zero failures | `/tmp/issue95-full-0666707.log` |
| Ordinary Xcode Release app build, signing disabled | **BUILD SUCCEEDED** on `0666707` | `/tmp/issue95-release-0666707.log` |
| Opt-in fixture Release arm64 build | PASS on `0666707`; Mach-O arm64; identity is `beepbar-isolated-ui-fixture-v1` | `/tmp/issue95-fixture-build-second.log` |
| Offline guard mutation in a disposable source copy | Compiled RED: offline-refresh assertion fails; original fixture PASS | `/tmp/issue95-offline-mutation-0666707.log` |

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

The scratch directory's name records its first attempt; the successful second build above
compiled the corrected `0666707` source. Identity verification uses `--harness-identity`, which
returns before constructing `NSApplication`. No ordinary app, installed app, signing identity,
real account or production data directory was launched or changed by these gates.

To reproduce the sensitivity check, export `0666707` with `git archive` into a fresh owned
temporary directory, change exactly the fixture's
`if account.offline { throw URLError(.notConnectedToInternet) }` to
`if false && account.offline { throw URLError(.notConnectedToInternet) }`, then run:

```sh
swift test --filter offlineRefreshRetainsKnownCoursesAndReportsFailure
```

It must compile and fail because `courseLoadError` is nil. Keep all URLProtocol injection,
unknown-host/token rejection and synthetic credentials unchanged. Run the unmodified fixture
suite for the green side; never remove the network interception as a mutation. The recorded
mutation used a disposable copy and deleted only that owned copy after preserving its log.

## Functional UI smoke, separate from measurements

All twelve short scenarios produced valid reports: cold/warm/offline, 100/500 courses,
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
