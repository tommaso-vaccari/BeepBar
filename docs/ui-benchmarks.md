# Isolated UI and launch fixture (D07 / #95)

`scripts/ui-benchmark.py` builds an opt-in fixture from a **committed source revision** and
runs the real Courses, Activity and Recordings SwiftUI views in the application's normal
configuration window. It never launches the normal BeepBar entry point or an installed app.
Current code gates, functional checks and unmeasured acceptance are in the
[D07 validation report](reports/isolated-ui-harness.md).

## Single command

Prerequisites: macOS Apple Silicon, Xcode matching CI with `xcrun xctrace` and Time Profiler,
AC power, Low Power Mode off, nominal thermal state, an unlocked GUI login session, and enough
temporary storage. Stop other builds/tests/downloads and keep the display and power conditions
constant. Instruments can require normal Developer Tools authorization; a refused prompt is a
measurement blocker, not a successful trace. Do not bypass a security prompt or accept an EULA
as part of a measurement run.

Commit the candidate, fetch remote refs, then run from the branch containing this driver:

```sh
scripts/ui-benchmark.py --ref HEAD --out PerformanceReports/ui-d07 --runs 5 --warmup 1
```

The default covers all scenarios below, including one **30-minute unprofiled idle observation**.
UI scenarios get one warm-up and five measured fresh fixture processes, each with a retained
Time Profiler trace plus `os_signpost` recording. Each `launch-warm` and `reopen-sync` process
opens/closes twice; reported warm
latency uses the second window. `memory-cycles` performs ten actual open/sync/close cycles per
process and records footprint after each closed-window settling period. UI controls are disabled
so an accidental click/shortcut cannot enter real login, Settings, updater or external actions.

For a focused tooling check (not the complete D07 acceptance series):

```sh
scripts/ui-benchmark.py --ref HEAD --out PerformanceReports/ui-d07-smoke \
  --scenarios courses-100 launch-warm activity-1000 recordings-1000 --runs 5 --warmup 1
```

The `--out` directory must not exist. The source SHA, driver/binary hashes, toolchain, machine,
power source, workload, commands and raw results are retained. The source is archived to an
owned temporary directory and compiled Release arm64 with `DEBUG` injection seams and
`UI_PERFORMANCE_HARNESS`. Compiled app/Core objects are not reused; only package dependency
checkouts/repositories/artifacts may be copied from `.build` or `--dependency-cache DIR`.
The renamed binary lives in an owned temporary bundle with a fresh fixture bundle ID. Before
launch the driver verifies its opt-in harness identity. No signing identity is used or installed
application modified. Build/bundle/fixture data are removed on success, failure and handled
interruption; logs and evidence remain. SIGKILL/power loss cannot run cleanup; `temporaryRoot`
in `series.json` identifies the owned leftover directory. Never delete unrelated paths.

## Isolation and workloads

Each fixture has its own UUID directory containing preferences, SQLite, root and synthetic
recording session. The existing injected controller constructor, notification client and
credential vault are reused. Every network request is intercepted by a token-scoped ephemeral
URLProtocol; unknown requests/hosts/tokens fail instead of reaching a real server. Recordings
uses an injected browser, never WebKit/SSO/default browser/pasteboard. Real scheduler,
notifications, Launch at Login and Sparkle are absent. The fixture icon has no interactive menu.

| Scenario | Workload / measurement |
|---|---|
| `launch-cold` | First window in a fresh fixture process with 100 known synthetic courses |
| `launch-warm` | Second open after releasing the first hierarchy, same controller/data |
| `launch-offline` | Known synthetic courses retained while mock refresh fails offline |
| `courses-100`, `courses-500` | 100 / 500 real Course rows/models, one enabled course |
| `reopen-sync` | Close and reopen while a genuine sync is held at its mock contents request, then release and drain |
| `activity-1000`, `activity-15000` | One course expanded with 1,000 / 15,000 real activity items |
| `recordings-1000`, `recordings-5000` | Synthetic reusable session and full listing through the real recording controller |
| `progress-burst` | 10,000 events from an off-main producer through the existing sync progress callback/relay |
| `memory-cycles` | Ten actual open/sync/close cycles, one enabled course, no file downloads |
| `idle` | Closed-window fixture for 1,800 seconds, before/after process counters and fixture request accounting |

There is a fixed 300ms shown settling period after refresh and 3s after each close. These are
not readiness estimates: key/content callbacks provide the reported latencies. A missing key
window or populated-content marker times out and invalidates the sample; a valid empty window
cannot substitute for a data row. A reduced/wrong corpus, wrong cycle count, nonfinite timing,
failed run, Low Power Mode or nonnominal end thermal state invalidates the series. Power is
checked before and after every process and after trace export. These are endpoint checks;
keep power unchanged throughout the run. Trace failure also fails the command: each required
trace must be nonempty and readable by Instruments export, identify the successful fixture,
and contain main-thread CPU samples with stacks plus all required UI signposts.
No timing table should be cited from an invalid series.

## Signals, budgets and interpretation

Signpost subsystem: `io.github.tvaccari.beepbar.performance`, category `ui`:

- `ui.iconReady`: the real status item's image has been assigned.
- `ui.fixtureOpen`: fixture starts constructing the shared configuration window.
- `ui.windowKey`: that window's key notification, measured independently of content.
- `ui.firstCourseContent`: first real course row appears in the hierarchy.
- `ui.firstActivityContent`: populated last-sync header appears.
- `ui.firstExpandedActivityContent`: first item of the expanded course appears.
- `ui.firstRecordingsContent`: first real recording row appears.
- `ui.fixtureProgressBurst`: interval containing synthetic progress publications.

Content signals use SwiftUI `onAppear` on populated rows/header. They prove hierarchy readiness,
**not compositor presentation or smooth scrolling**. Window key latency targets remain 250ms
first-window / 100ms same-process reopen; report key and content separately, including failures.
`iconConstructionMilliseconds` measures only status-item construction after fixture preparation:
it does **not** establish the production app's 200ms launch-to-icon budget. Fixture setup is
reported separately. The cold scenario does not purge OS caches or run the production credential,
bootstrap/migration path. The offline scenario does not prove persisted cold offline course
restoration; that remains D10. These gaps keep D07's full launch acceptance open.

Inspect each retained `.trace` in Instruments, select the fixture's main thread, and examine
window construction, content appearance, expanded Activity, recording list and progress bursts.
Time Profiler sampling reveals occupied stacks; a maximum sample gap is not a proof of every
main-thread stall. Independently validate the 16ms responsiveness budget using an appropriate
trace and isolated scrolling/actions. Record regressions and main-thread stacks; do not infer
app-wide responsiveness from these synthetic elapsed timings alone.

After ten cycles compare stabilized closed-window footprint against cycle 1 (target ±2 MiB).
The workload uses one enabled course and empty mock contents, not ten full production downloads.
Idle reports process CPU (Mach timebase converted), writes, wakeups, footprint and intercepted
fixture requests. There are zero due production scheduler checks **by construction**, as required
for the isolated baseline; this does not validate production scheduler cadence or all network
traffic caused by the OS. The observer arms only the end deadline and has no sampling/poll timer.

Five runs produce an unstable nearest-rank p95 equal to the maximum. Preserve range and individual
samples, expand sampling before claiming a reliable tail, and record negative findings. The report
reports each scenario's maximum observed key latency against its 250ms/100ms target. A slow
but otherwise valid sample remains evidence and reports a violated budget; it is not discarded.
The target check applies to the observed samples and does not establish the population tail.
These results establish tooling evidence, not performance benefits. Base-dev → HEAD and main → HEAD UI
comparisons need an equivalent, reviewed fixture on every revision and are explicitly unmeasured
until that exists. Keep D07 open until the full launch, main-thread/scroll/action, idle and memory
acceptance evidence has been checked; a partial tooling PR must use `Refs #95`, not `Closes #95`.

## Tooling verification

```sh
python3 scripts/test_ui_benchmark.py
swift test --filter UIFixtureTests
swift test
xcodebuild -project Beepbar.xcodeproj -target Beepbar -configuration Release build CODE_SIGNING_ALLOWED=NO
```

The focused suite checks token/defaults/root isolation, malformed workloads, immutable reports,
offline known-model retention, fail-closed requests, full corpora and a genuine held sync. The
safe regression mutation is removal of the mock offline guard in a disposable copy: the offline
refresh test must fail while every request still remains intercepted. Never mutate away the
network protocol injection and then run tests against a real Moodle host.

Outputs: `series.json`, `series.md`, `build.log`, and one directory per scenario with raw fixture
JSON, process/trace logs, traces, and exported TOC/CPU/signpost XML for UI samples. Exported TOCs
remove the device owner name/UUID. Runtime failures retain `valid: false`; a
single failing scenario invalidates the full series. Raw reports/traces are ignored by Git and
must be preserved locally. Original Instruments traces can contain device identity metadata;
share only reviewed, sanitized exports/summaries in the PR and shared documentation.
