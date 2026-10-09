# Benchmarks

The benchmark harness measures BeepBar against the performance budgets in `AGENTS.md`. It runs on
demand, and every performance PR uses it for its before/after numbers. The regular `swift test`
only runs its own tests and a tiny run of each scenario, about a second in all.

## Safety

- **Synthetic data only.**
  - The corpus is generated: course names, file names, sizes and bytes.
  - Every run happens in a new temporary folder, holding its own sync folder, its own `sync.sqlite` and its own trash folder. All of it is deleted afterwards.
  - Download bodies stream to the downloader's own temporary files (`$TMPDIR/Beepbar-download-*`), as in the app, and are removed when each download ends.
- **The user's data is never touched.** That covers:
  - the WeBeep account and the keychain token (a fixed fake token is used);
  - `~/Library/Application Support/Beepbar`;
  - UserDefaults;
  - the sync folder;
  - the Trash.
- **No real network.** Moodle is an in-process mock behind a `URLProtocol`, registered only on the benchmark's own `URLSession` and on a host of the form `<uuid>.bench.beepbar.test`.
- **The app is never launched.** A locally built Release app shares its bundle id, and with it all the state above, with the installed copy.
  - The scenarios drive `BeepbarCore` directly.
  - The idle measurement only watches the installed app, passively.

## Running

```bash
scripts/benchmark.sh                       # every scenario → PerformanceReports/baseline-<date>/
scripts/benchmark.sh unchanged --files 15000
scripts/benchmark.sh large-update --size-mb 512 --runs 5
scripts/benchmark.sh cancel --fraction 0.5 --rate-mbps 100
scripts/measure-idle.sh                    # 30 min, the installed Beepbar, passive
```

`scripts/benchmark.sh`:
- builds `beepbar-bench` with `swift build -c release --arch arm64`;
- passes it the current commit, plus `--dirty` when tracked files have uncommitted changes;
- warns when the Mac is on battery.

`baseline` runs each scenario in its own process, so one scenario's memory high-water mark doesn't colour the next. It writes:
- one JSON file per scenario;
- a merged `baseline.json`;
- `baseline.txt`, the table also printed on screen.

Options are validated before any benchmark work: unknown or wrong-command options, duplicates, missing values and invalid numeric values exit with status 64 and usage. Use `baseline --out DIR` for baseline output; `--json PATH` belongs to individual scenarios and `idle`. `--runs` and `--warmup` apply to scenarios and baseline. The wrapper supplies `--commit` and `--dirty`; do not repeat them.

`PerformanceReports/` is git-ignored.

The command exits non-zero when a scenario's checks fail (for example, a "nothing new" run that installed files). A number from a failed scenario measures something else and must not be quoted.

**Comparing numbers** (AGENTS.md):
- use the Release arm64 build only;
- run on the same machine and the same power source, plugged in;
- report the median and p95 of five warm runs (`--runs 5 --warmup 1`, the default).

Every report records the commit, the machine model, the CPU, the memory, the macOS version, the power source, Low Power Mode, the thermal state and the build configuration.

## Scenarios

**`unchanged`: a run with nothing new.**
- *Budget:* ≤ 50 ms of local work per 1,000 tracked files, no file hashing, no database or disk writes, minimal requests.
- *Setup:* `--files` files over 10 courses, or one course per 1,000 files above 10,000.
- *Each run:* repeats the Core work of an automatic check (see "What a run covers") while Moodle has nothing new.
- *Checks:* nothing installed, no downloads, no failures or conflicts, the same work every run. These make the run valid; they are not the budget.
- *Budget lines:* the report adds whether the run hashed no file and wrote no database page or disk byte. A budget not met is reported, not failed: the numbers are still worth quoting, and fixing them is the performance PR's job.

**`large-update`: one large file changes on every run.**
- *Budget:* peak memory independent of file size, throughput bound by the network.
- *What it reports:* the peak footprint during the run (`memory.peak`), and `fs.bytesHashed` against the file size, i.e. how many times the file was read.
- *Baseline sizes:* 64 MiB and 256 MiB, so the two peaks can be compared.
- *Note:* the mock is unthrottled, so throughput here measures the local pipeline, not a network.

**`cancel`: cancel during a large update.**
- *Budget:* stopped within 1 s at p95, even mid-way through a large file.
- *Setup:* the mock is throttled (`--rate-mbps`), and the run's task is cancelled once `--fraction` of the file has been sent.
- *What it reports:* `cancel.latency`, from `Task.cancel()` until the run returns.
- *Checks:* every run ended cancelled, before the whole file was sent when `--fraction` is below 1, and the previously installed file still has its exact bytes (SHA-256 compared after every run).
- *Note:* `--fraction 1` cancels as the last chunk leaves the mock, which is the closest the harness gets to "after the download".

## Counters

Every counter is the change during one run.

| Metric | Source | Meaning |
|---|---|---|
| `wall`, `cpu`, `instructions` | `ContinuousClock`, `proc_pid_rusage` | Whole benchmark process: the sync plus the mock (answers pre-rendered, a 0.2 ms poll while a download waits on its flow-control window) and the 1 ms footprint sampler, both small next to the sync |
| `disk.written`, `disk.logicalWritten` | `proc_pid_rusage` | Bytes written to storage, and including those still in the page cache |
| `memory.peak`, `memory.peakGrowth` | `PeakFootprintSampler` (1 ms) | Highest `phys_footprint` of the process during the run, and that minus the value just before. Compare `memory.peak` across file sizes. `memory.peakGrowth` reads near zero after a warm-up even when a run needs hundreds of MiB, because the allocator keeps what the previous run freed |
| `db.commits` | SQLite commit hook | Write transactions committed. An empty transaction, or a write matching no row, still counts. Only commits that wrote pages (`db.pagesWritten`) append to the WAL and wait for an `fsync` |
| `db.ownershipBackfill.transactions`, `db.ownershipBackfill.updates` | Connection-local attempt counters | Ownership migration write transactions and per-row UPDATEs attempted, including failed attempts; separate from rows actually changed |
| `db.rowChanges` | `sqlite3_total_changes64` | Rows inserted, updated or deleted, identical rewrites included |
| `db.pagesWritten` | `SQLITE_DBSTATUS_CACHE_WRITE` | WAL frames. An `UPDATE` that leaves a page byte-identical writes none |
| `fs.filesHashed`, `fs.bytesHashed` | `FileStore.counters()` | Full-content SHA-256 reads, and the bytes they read |
| `fs.pathLookups` | `FileStore.counters()` | Paths resolved from the sync root before touching a file |
| `net.*` | mock counters | Requests by kind, metadata bytes, downloaded bytes |

The database and filesystem counters are `package`-level API in `BeepbarCore`. Tests use them to prove properties like "a run with nothing new writes nothing" (`WorkCountersTests` shows what each one counts).

## What a run covers

`BenchmarkFixture.automaticRun` mirrors the Core part of the app's automatic sync (`runAutomaticSync` and `completeSync` in `WeBeepAuthenticationController`), in this order:
1. Read the enabled courses.
2. Ask for the site info, only the first time.
3. List the enrolled courses.
4. Run a new `SyncCoordinator` in `.automatic` mode with a new `FileStore`.
5. Read the open conflicts and pending changes.

**Not covered**, because it lives in the app:
- the keychain read;
- the UserDefaults writes of the sync state (the last summary and the reconciliation time);
- the "Risparmio dati" setting: runs always use `.unrestricted`;
- notifications;
- UI updates.

Keep `automaticRun` in step with the app when that sequence changes.

## Idle

`scripts/measure-idle.sh [minutes]` finds the Beepbar running from `/Applications` and samples it with `proc_pid_rusage` every minute (`beepbar-bench idle --pid`).
- *What it reports:* average CPU, interrupt wakeups per second (with how many brought the CPU out of idle), disk writes and footprint growth.
- *Network:* `nettop` samples the process's open connections every second for the whole window, and each connection counts the most bytes it was seen with, minus what it had moved before the window. `nettop` forgets a connection once it closes, so two snapshots would read 0 after a check that came and went. A connection opened and closed between two samples is still missed, so the number is a lower bound, printed with the count of connections seen.
- *Before measuring:* close BeepBar's window and leave the Mac alone. An automatic check that falls inside the window is expected and shows up as one burst.

## Profiling

The scenarios run the same code paths as the app, so the `PerformanceTrace` signposts (subsystem `io.github.tvaccari.beepbar.performance`, categories `sync`, `database`, `filesystem`, …) show up when `beepbar-bench` runs under Instruments:

```bash
xcrun xctrace record --template 'Time Profiler' --launch -- "$(swift build -c release --arch arm64 --show-bin-path)/beepbar-bench" unchanged --files 15000
```

The `Beepbar-Profile` scheme profiles the app itself. Never use it to launch a local build: it would share the installed app's data.

## Extending

Add a scenario to `Scenarios` with its own checks, register it in `Sources/BeepbarBenchmarks/main.swift` (and in `baseline` if it belongs to the standard set), and give it a small smoke test in `BenchmarkKitTests`.
- New request types belong in `BenchmarkUpstream`.
- New counters belong in Core, with a test in `WorkCountersTests` proving what they count.

Extend the harness rather than writing one-off scripts.

## Persisted Activity summary restore

Run the on-demand controller benchmark without launching the app:

```sh
BEEPBAR_RESTORE_BENCHMARK=1 swift test -c release --arch arm64 -Xswiftc -DDEBUG --filter SyncFinalizationTests/benchmarkSummaryRestore
```

Release optimization remains enabled; `DEBUG` enables the existing isolated controller constructor and test hooks. All data, defaults and SQLite are temporary; no account, real preferences or network is used. The test is disabled in regular CI. It restores synthetic summaries containing 1,000 and 15,000 file details, warms up once and prints seven samples, JSON size, write attempts, end-to-end restore latency and separate synchronous codec timings. Compare the same configuration on the same machine and power source, without concurrent builds/tests. End-to-end async latency is not main-thread occupancy: use the codec timings to justify moving decode work and Instruments to validate UI latency. New-result encoding remains a separate path.

## Reproducible ref comparisons (single agent command)

Use the existing harness through `scripts/benchmark.sh compare`. It never checks out a ref in
this checkout, launches/installs the app, or measures real accounts/network. It archives each
full source SHA into its own temporary directory and builds `beepbar-bench` Release arm64.

Prerequisites: macOS on Apple Silicon, Xcode/Swift matching CI, Git, Python 3.9+ (standard library
only), AC power, Low Power Mode off, nominal thermal state, enough temporary disk space and
resolved Swift package dependencies. The command copies only dependency artifacts/checkouts/
repositories from `.build` (or `--dependency-cache DIR`); it never reuses compiled app/Core objects.
Dependency resolution is disabled: missing dependencies fail with retained build logs. Build
sandbox disabling is limited to SwiftPM in isolated source directories. Do not run builds/tests
concurrently with measurements. Default sampling is five measured runs after one warm-up.

Agent steps:

1. Read the project instructions and measurement requirements; inspect `git status` and preserve
   user changes. Fetch remote refs explicitly before measuring: `git fetch origin`.
2. Commit the candidate on its feature branch. Choose the PR's actual base-dev SHA and freeze main
   for this series; a later release requires a separately named output series.
3. Run the single command from a checkout containing this tooling (the measured candidate can be
   another ref). Each ref is resolved to a full SHA exactly once before any build. `--out` must not
   exist; existing evidence is never overwritten.

```sh
scripts/benchmark.sh compare --main origin/main --base-dev origin/dev \
  --candidate HEAD --out PerformanceReports/my-change --runs 5 --warmup 1
```

4. If native measurement source trees differ, the command refuses the comparison. Inspect the
   differences first. Explicitly choose one committed harness for all three production revisions
   with `--harness-ref REF`. Only `Sources/BeepbarBenchmarkKit` and `Sources/BeepbarBenchmarks` are
   overlaid; production sources, package manifest and dependencies remain from each source SHA.
   Build/API incompatibility fails instead of patching production. Selecting an older harness
   means its newer counters are unmeasured. Every overlay is retained as a per-ref patch and
   native/effective file SHA-256 identities; adjusted raw reports carry `dirty: true`.

The released fixture historically omitted saved folder overrides. To reproduce the explicitly
matched fixture documented in the existing `2026-10-09-main-vs-dev/conditions.log`, choose an old
harness and request this specific fixture-only adjustment:

```sh
scripts/benchmark.sh compare --main origin/main --base-dev origin/dev \
  --candidate HEAD --harness-ref origin/main --saved-folder-overrides \
  --out PerformanceReports/my-change-matched --runs 5 --warmup 1
```

`--saved-folder-overrides` persists normal module destinations before the setup sync on all
three revisions. It requires `--harness-ref`, refuses an already adjusted or unrecognized fixture,
and records the option, effective hashes and actual source patches. It changes no application code.
A harness selection is an explicit measurement policy; inspect its checks/workload against the
budget being evaluated. Unknown metrics or raw-report schemas are refused. If an API, manifest,
fixture or instrumentation cannot be made equivalent using these measurement-only options,
report **not measured** and extend the existing harness with a reviewed adjustment first.

5. Check exit status, `comparison.json` validity and every scenario's checks. Reports must agree
   on scenario name/parameters, check names, warm-up, sample counts, machine, OS, power and build.
   Metric distributions are recalculated from raw samples and checked against the harness JSON.
   Failed subprocesses, missing/invalid samples or incompatible reports never produce valid rows.
   Costs increasing at either median or p95 are marked regressions; delta is candidate minus base,
   percentage is cost reduction `(base - candidate) / base * 100`. A zero baseline has no percentage.
6. Paste `comparison.md` into the PR and retain the output directory. Separate tooling validation
   from measured app gains. Include regressions, spread and limitations; Core timings establish
   no UI, idle or real-network improvement. With five runs p95 is the maximum, not a stable tail estimate.

Exit codes: **0** all comparisons valid (regressions still appear), **1** invalid comparison/build/
subprocess/report or output error, **64** invalid arguments, **130** interruption (SIGINT/SIGTERM).
Failure results and diagnostics remain; incomplete runs have `valid: false`. An output directory
creation failure leaves the existing directory untouched. Temporary source/build/fixture/dependency
and module-cache files owned by this command are removed on success, failure and handled interruption;
logs/results stay. SIGKILL or power loss cannot run cleanup; `temporaryRoot` identifies the owned
leftover directory. Never delete unrelated paths or existing reports.

Output layout:

```text
comparison.json                 SHAs, refs, driver hash, effective/native harness hashes,
                                commands/exits, toolchain/environments, comparisons, limitations
comparison.md                   PR table: units, median/p95, absolute/% deltas, regressions
{main,base-dev,candidate}-*.log  export/build/toolchain diagnostics
*-measurement.patch            explicit per-source measurement adjustments
{main,base-dev,candidate}/       each scenario's raw JSON (samples/checks/notes/environment) + log
```

The standard plan is unchanged 1k/15k, updates 64/256 MiB and mid-download cancellation.
For a real end-to-end tooling smoke test, append `--smoke`; it uses 10 files, a 1 MiB update and
4 MiB throttled cancellation with identical sampling on all three refs. Smoke reports explicitly
state that the reduced corpus does not establish the standard baseline.

Run safeguards locally with `python3 scripts/test_benchmark_compare.py`; CI runs these alongside
`swift test`. Mutation checks must use a disposable copy, especially for cleanup changes.
