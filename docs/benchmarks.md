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
scripts/benchmark.sh startup --files 15000 --phase first   # or --phase later, --files 0 for an empty database
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

**`startup`: one launch's database work on a degraded database (R02, issue #110).**
- *What it measures:* what `BootstrapService.prepare` does at every app start: open `sync.sqlite` (which reruns the whole schema migration in one transaction), `registerRoot`, recovery. In the app this runs on `BootstrapService`'s own actor while the menu shows the starting state, not on the main actor.
- *Setup:* `LegacyDatabaseFixture` builds `--files` tracked files (default 15,000; 0 allowed with `--phase later` only) through today's schema, then degrades it: half the rows without an owning module, 40 rows with a course but no module, no recorded migration versions, the later releases' tables and index dropped.
- *`--phase first`:* the first launch after updating. Every run, warm-up included, gets a fresh degraded fixture, so every sample is a real repair; it needs `--files 6` or more, since a smaller corpus has no half-attributed row and its checks would pass with the repair removed. *Checks:* the half-attributed rows are repaired, the dropped tables and index and the deleted versions are back (both counted on the fixture, not assumed, so an older or newer ref is checked against its own schema), only those rows and versions changed, every tracked file is kept, recovery finds nothing.
- *`--phase later`* (default): every launch after that. The repair runs once in setup, unmeasured; each run reopens the file on a new SQLite connection (the OS page cache stays warm). *Checks:* no row or page written, the same work every run, no ownership backfill or module-override work, every tracked file kept, recovery finds nothing.
- *`--files`* is at most 1,000,000 here. The fixture models a half-attributed `items` table (an upgraded table has no `CHECK` against it); the upgrade from a release without module ownership (v2.0.106) is covered by `StartupMigrationTests` in Core instead.
- *What it reports:* `wall` is the whole launch and `db.*` the launch's own connection; `notes` split open+migrate from the whole launch. `cpu` includes the 1 ms peak-memory sampler thread, so it can exceed `wall` on sub-millisecond launches. The samples use the common metric set on purpose, so `compare` can validate them like every other scenario.
- *In `baseline` and `compare`:* `startup-first-15k` and `startup-later-15k`; the smoke comparison runs `startup-smoke` (100 files, first launch). A harness selected with `--harness-ref` that predates this scenario (it has no `StartupScenario.swift`) leaves them out and records them as not measured in the report's limitations, instead of failing every build of the series.

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
| `fs.pathLookups` | `FileStore.counters()` | Directory resolutions from the sync root before touching the files in them. Per-file calls resolve once per path; the bulk existence check of a run with nothing new resolves each distinct parent folder once per call, and a run makes a few such calls (R03, #111), so `unchanged` counts module folders, not tracked files. Reports from before R03 count one per tracked file |
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
- the UserDefaults writes of the sync state (the last summary and the reconciliation time): the
  controller benchmark in [Persisted Activity summary save](#persisted-activity-summary-save)
  measures them;
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

Release optimization remains enabled; `DEBUG` enables the existing isolated controller constructor and test hooks. All data, defaults and SQLite are temporary; no account, real preferences or network is used. The test is disabled in regular CI. It restores synthetic summaries containing 1,000 and 15,000 file details, warms up once and prints seven samples, JSON size, write attempts, end-to-end restore latency and separate synchronous codec timings. Compare the same configuration on the same machine and power source, without concurrent builds/tests. End-to-end async latency is not main-thread occupancy: use the codec timings to justify moving decode work and Instruments to validate UI latency. New-result encoding is measured by the save benchmark below.

## Persisted Activity summary save

Run the on-demand controller benchmark of a sync's new result (R01, #109) without launching the app:

```sh
BEEPBAR_PERSIST_BENCHMARK=1 swift test -c release --arch arm64 -Xswiftc -DDEBUG --filter SyncFinalizationTests/benchmarkSummaryPersist
```

The same conditions as the restore benchmark apply: Release optimization with `DEBUG` for the
isolated controller and its hooks, a throwaway defaults suite in a temporary folder, temporary
SQLite, no account, real preferences or network, and disabled in regular CI. It saves synthetic
results with 0 (no course entries, as a sync with nothing new), 1,000, 5,000 and 15,000 file
details over ten courses, warms up once and prints five samples per size (`PERSIST_BENCH`) and
their median and nearest-rank p95 (`PERSIST_SUMMARY`) for:

- `inline_turn`: `setSyncState(.synced)`, the main-actor turn that encodes and writes. It was the
  completion path before R01 and is still the legacy-migration path;
- `encode` and `writes`: its two parts alone;
- `off_main_encode`: `EncodedSyncSummary.encode`, awaited from the main actor; it lengthens the end
  of the sync but does not occupy the main actor;
- `turn`: `setSyncState(synced:)`, the main-actor turn of the completion path since R01, which
  publishes and writes bytes already encoded.

Each sample checks, outside the timed windows, that exactly the two keys were written and that the
saved bytes decode to the published result. The turn excludes SwiftUI rendering, which needs the
isolated UI harness. Refs without `EncodedSyncSummary` (before R01) can be measured for
`inline_turn`, `encode` and `writes` with a measurement-only copy of the benchmark limited to those
three timings; record such a copy as a measurement-only adjustment.

## Directory traversal profile

The opt-in `DirectoryTraversalProfileTests` measures only `FileStore.existingRegularFiles`, the per-file part of a run with nothing new, over three synthetic layouts of 15,000 empty files: 50 folders two levels deep (like `unchanged`), 500 folders four levels deep, and one file per folder three levels deep (the worst case for grouping by folder). It prints the median and maximum of five runs after one warm-up, and the `FileStore` counters.

```sh
BEEPBAR_TRAVERSAL_PROFILE=1 swift test -c release --arch arm64 -Xswiftc -DDEBUG --filter DirectoryTraversalProfileTests
```

`-DDEBUG` only lets the app test target compile in release, as for the restore benchmark above; `BEEPBAR_TRAVERSAL_FILES` changes the file count. The test uses only API that predates R03, so to measure an older commit, check it out in a disposable detached worktree, copy the test file there and run the same command. Files live in a temporary folder that is deleted afterwards. It is a Core micro-measurement: use `unchanged` for the numbers a PR compares.

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

## Isolated UI and launch measurements

D07's opt-in fixture and single-command scenario runner are documented in
[UI benchmarks](ui-benchmarks.md). It hosts the actual pages with synthetic dependencies and
reports window key separately from populated-content readiness. Its timings and traces must
not be confused with the Core comparison harness or production launch/scheduler evidence.

## Enhanced audio (live filter)

Measure the local work of enhanced audio on a synthetic lecture, without the app, the network or an account:

```sh
BEEPBAR_MEASURE_AUDIO=1 swift test --filter LiveAudioMeasurements
```

It needs ffmpeg where BeepBar looks for it (`/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin`) and the system speech synthesizer; without either, or without the variable, the suite is skipped, so it never slows the regular `swift test`. The lecture is six minutes laid out as Webex's (one fragmented MP4, 30-second segments, 720p, 44.1 kHz stereo voice), made once in the temporary folder and read from disk, so network time is left out. Each variant (`isolation=true kind=isolated` and `isolation=true kind=levelled` with Apple's voice isolation, `isolation=false` with ffmpeg only) asks for segments as the player would: the first (`seg0`), the next two, a seek ahead (`seg8`) and a seek back to a part already heard (`seg1`). It prints the wait for each with the memory footprint read just after the answer (`BEEPBAR_MEASURE_AUDIO_SEGMENTS=all` asks for all twelve segments in order instead, to see whether memory keeps growing), the time spent in each step (`decode`, `isolate`, `encode`, `probe`, with counts), the CPU of BeepBar and of ffmpeg, the memory footprint before, at peak and after stop, and fails if stopping leaves a file or a child process behind.

The same suite prints `LEVELLING 62 s clip` with the median and max, in ms, of `VoiceLeveler.gains` (runs on the pipeline actor) and `level` over five runs.

Report five runs per commit, interleaved and on the same machine and power source, with median and p95 of each wait. A commit older than the harness needs the file copied in and, if an API changed, a measurement-only adaptation recorded with the numbers. After stop the footprint stays at its peak while isolation is used: the voice model stays loaded in the process (the same at the commit before the piece cache), which is not a leak per session.

### Enhanced audio quality

Measure what the filter chain does to the teacher's voice at any distance from the microphone, on a synthetic classroom (macOS `say` voices and ffmpeg noise, generated on the spot; no real lecture):

```sh
BEEPBAR_MEASURE_AUDIO_QUALITY=1 swift test --filter AudioQualityMeasurements
```

Same requirements as above (ffmpeg, `say`); without the variable the suite is skipped. It takes about ten minutes in a debug build. Tests: `matrix` (the table and summary), `endings` (word endings through the unit, near and far), `longPause` (a teacher silent for half a minute, noise only and with students), `joins` (segment seams and the warm-up after a seek), `wetDryAlignment` (whether the unit's dry path lines up with its wet one) and `abRenders` (listening files and real-excerpt metrics).

The scene is built from separate stems at 48 kHz mono: a teacher (nine sentences, one every 10 s, 5 s or more of pause after each; speech regions at −22 dBFS RMS at gain 0), students (another voice, continuous) and steady noise (pink noise with a 100 Hz hum). The matrix is teacher gain 0, −10, −20, −30 dB × students none, −20, −30 dB × noise −35, −50 dB (students and noise relative to the teacher, so the whole scene moves with the gain), plus a moving teacher (0 → −20 → 0 dB every 15 s, background fixed). Every cell is made twice, with a near teacher and with a far, reverberant one (the same sentences convolved with a decaying-noise response, reverberation time about 0.8 s, high frequencies rolled off, 10 dB quieter). Teacher gains −30 and −40 dB with students −20 dB reach the level of a real, distant recording. Each cell goes through a front (`raw`: none; `iso100`, `iso90`, `iso85`: Apple voice isolation, the real unit, at 100, 90 and 85% wet) and then each candidate chain, defined in the suite, read the way the production encode read it before the leveler. `current` is the chain shipped before the leveler, which production no longer has: the suite keeps a frozen copy (`AudioQualityMeasurements.swift:55`, `chainBeforeLeveler`); `isolation-only` is the front alone, to tell the unit's effect from the chain's.

Environment:

- `BEEPBAR_AUDIO_ONLY=C1,C2`: only those candidates (and `current`, `isolation-only`).
- `BEEPBAR_AUDIO_QUICK=1`: only students −20 and noise −35, to iterate.
- `BEEPBAR_AUDIO_AB_OUT=<folder>`: `abRenders` writes 16-bit mono WAVs named `<scene>__<front>__<candidate>.wav` for several synthetic scenes (near and far teacher with students, a very quiet teacher, a moving teacher, a reverberant far teacher). With `BEEPBAR_AUDIO_EXCERPT=<file>[,<file>]` it renders the same candidates from the first audio track (180 s at most) of each local file as `excerpt<n>__<front>__<candidate>.wav`, `n` being the position in the list, and prints for each render the loudness and range, the peak and clipped samples, how far the floor and the speech moved, the gain's standard deviation in the quietest frames (noise pumping) and an approximate word-ending loss. Those files are private: they are read in place, never copied into the repository, and their names, paths and contents are never printed or documented. `BEEPBAR_AUDIO_EXCERPT_ONLY=1` skips the synthetic scenes. Set `BEEPBAR_AUDIO_ONLY` too: every candidate is a file of several megabytes.

What the output means (all in dB; lower is better unless noted):

- **spread**: the teacher's speech level out, max − min across the four gains with the same students and noise. The input spread is 30 dB; a chain that levels scores near 0. **near−far** is the same for the moving teacher (input 20 dB).
- **gap Δ**: (speech level − pause level) out minus the same in, over the static cells (min and median). Negative means the background was raised relative to the teacher ("noise remains"); higher is cleaner.
- **soft loss** (mean, and the worst 5th percentile over the four gains): on the teacher alone, how much more the soft frames (20 ms frames 12–30 dB under the 95th percentile of speech) lose than the loud ones (top 12 dB), out aligned to in by cross-correlation. Closer to 0 is better; negative means word endings and soft consonants are being cut. **ending** is the same over the last 300 ms of each sentence. `isolation-only` shows how much of it is the Apple unit's.
- **pump**: standard deviation of the per-frame gain over the loud frames; a steady chain scores near 0.
- **loudness** (median speech RMS, dBFS), **max peak** (the test fails above −1.9 dBFS, except `isolation-only`, which has no limiter) and **delay** (samples, out against in).
- **LUFS / LRA**: integrated loudness and loudness range (EBU R128) of the moving scene, as a listener hears it.
- **ENDING** (`endings`): the last 120 ms of each speech region against the rest of the region, output minus input, so a pure gain cancels (negative: the ending is cut); median and worst 10% over regions and gains 0, −20, −30 and −40. Rank on the worst 10%: a compressor with make-up gain raises quiet tails and lifts the median.
- **LONG** (`longPause`): speech minus pause level in and out, and the pause's absolute level (−120 is digital silence, a finding in itself).
- **JOIN** (`joins`): a 90 s scene filtered whole and in three 30 s pieces (Webex's segment length) with 30, 12, 6 and 0 s of context before and 30 s after, trimmed and joined as the player's segments are (production has the previous segment only if it is already on disk, so none after a seek); the level difference between the two in 100 ms frames within 1 s of each join and in the first 5 s of the piece after it (the warm-up of a leveler that has just started), median and max, the same in the middle of a piece for comparison, `step` (largest level change between 20 ms frames across a join that the whole file lacks) and `click` (sample jump against the whole file).

Run it on the commit that changes a chain and on `dev`, interleaved, on the same machine; report the summary lines and the join lines. It measures chains on synthetic speech only: the ear (`abRenders`) and a real excerpt decide what it cannot.

### Enhanced audio: keypoint leveler (round 2)

`KeypointLevelerMeasurements` (on demand, same `BEEPBAR_MEASURE_AUDIO_QUALITY=1` gate; plain `swift test` skips it) prototypes candidate G as pure functions (`KeypointLeveler`, test target only) and renders it on **local** recordings. Real lectures are private: they are read from a temporary location, never copied into the repository, and only an index is printed.

Variables: `BEEPBAR_AUDIO_LEVELER_EXCERPTS` (comma-separated files, first 180 s used), `BEEPBAR_AUDIO_LEVELER_CACHE` (folder keeping the slow isolation between runs, outside the repository), `BEEPBAR_AUDIO_LEVELER_LABELS`, `BEEPBAR_AUDIO_LEVELER_BEST` (variant written as `new`), `BEEPBAR_AUDIO_AB_OUT` (listening files), `BEEPBAR_AUDIO_LEVELER_LECTURE` (a whole lecture), `BEEPBAR_AUDIO_LEVELER_INVARIANCE` (`<excerpt>:<dB>,...`).

Select a test with `swift test --skip-build --filter "KeypointLevelerMeasurements/<name>"`:
- `tune`: compressor settings after the leveler, aiming at -18..-16 LUFS.
- `renders`: per excerpt, G and its variants (no ceiling, spacing 5, percentile 95, target -23, hold 3, leveling after the EQ, ceiling headroom 10 and 14 dB, gentle expanders) against `current` and `isolation-only`: `LEV` (LUFS/LRA, speech level in/out, limiter worst, peak, ending metric), `HISS` (non-speech residue after the chain, absolute and relative to speech), `CEIL` (share of instants where the ceiling acts) and `JUMP` (limiter reduction after the largest level rise). Writes `original`, `current`, `new` and `original-loud` listening files.
- `levelInvariance`: isolation of a signal vs isolation of the same signal scaled by a pre-gain and scaled back (`INV`, plus the ending metric of each against the other).
- `transients`: a synthetic scene with door, knock, scrape, clicks and cough bursts in pauses and under speech (`TRANS`): what survives isolation, the keypoint gain with and without bursts, the hold rule on a bursts-only window, clipping.
- `seams`: whether a piece rendered alone gets the whole lecture's gain curve, per lead and tail (`SEAM`), and how the hold rule chains across long silences for several `maxHold` bounds (`HOLD`).
- `wholeLecture`: G alone over a whole lecture: gain curve summary and processing time (needs about 1.2 GB of memory for a 95 minute lecture).

### Enhanced audio: keypoint leveler (round 3)

Same suite and gate (`KeypointLevelerRound3.swift`); the six excerpts are 180 s each from four private lectures and appear only as an index. Additional variables: `BEEPBAR_AUDIO_LEVELER_CLEANUP` (a `cleanupNames` entry, default `none`) and `BEEPBAR_AUDIO_LEVELER_COMPRESSOR` (a `compressors3` name, default `K7`).

- `cleanup` (`CLEAN`): hiss stages after the leveler (`afftdn` and gentle expanders) against the leveler alone: speech level, residue between words and in pauses, loudness, ending metric.
- `limiterLoad` (`LOAD`): each `compressors3` row after G: the limiter's reduction over 10 ms frames (median, 99th percentile, maximum), loudness and range, and the share of 50 ms frames between −50 and −30 dBFS (how much low-level material was lifted). The ratio 2 rows have their makeup calibrated per excerpt to the round-2 loudness.
- `pieces` and `forwardSeams` (`PIECE`, `FWD`): the gain curve of a piece rendered alone against the whole lecture's, with and without the previous piece's 12 s of history, and the step at each seam when playing forward after a seek.
- `fallback` (`FALL`): the chains that need no Swift leveler, on the isolated audio and on the original audio without isolation, against `current` and G.
- `listening`: writes `<n>-<label>__original-loud|current|new-r2|new-r3.wav` to `BEEPBAR_AUDIO_AB_OUT`.

Results (Apple M5, 32 GB, debug build, commit `ae299cd`; one run each, the chains are deterministic):

- **Cleanup: none.** No `afftdn` or expander variant improved the residue without costing word endings; the isolator already leaves digital silence in the pauses. The `between-word` and `pause` figures track quiet speech and short noises rather than hiss, and on an excerpt whose level changes they count the quiet half's speech as pause: do not rank chains on them.
- **Compressor: K17** (`threshold=0.08:ratio=3:attack=1:release=100:knee=6:makeup=4.52`), replacing round 2's K7 (`attack=10:release=200:knee=4:makeup=3.8`). Selection rule: limiter reduction p99 at most 3 dB, −18..−16 LUFS, least low-level lift.

  | Excerpt | K7 LUFS | K7 limiter p99 / max (dB) | K7 low-level frames | K17 LUFS | K17 limiter p99 / max (dB) | K17 low-level frames |
  |---|---|---|---|---|---|---|
  | 1 quiet, steady | −17.3 | 1.8 / 5.9 | 16.5% | −16.9 | 1.0 / 3.5 | 14.4% |
  | 2 loud, level change | −16.7 | 2.5 / 8.0 | 11.9% | −16.3 | 1.6 / 4.0 | 11.5% |
  | 3 quiet body | −18.8 | 0.0 / 2.7 | 16.3% | −18.1 | 0.0 / 1.1 | 15.2% |
  | 4 loud then quiet | −17.5 | 0.0 / 2.4 | 18.2% | −16.9 | 0.0 / 1.8 | 16.9% |
  | 5 normal | −17.8 | 1.3 / 7.2 | 14.3% | −17.2 | 0.4 / 3.7 | 12.4% |
  | 6 normal | −17.3 | 0.9 / 4.8 | 14.3% | −16.7 | 0.0 / 2.6 | 13.2% |

  K17 is 0.4 to 0.7 LU louder with half the limiter's worst reduction and fewer low-level frames. Excerpt 3 ends 0.1 LU under the range. Rejected: a 25 ms attack and the ratio 2 rows (p99 3.9 to 4.4 dB on excerpt 2), ratio 4 and 5 with a low threshold (−21 to −23 LUFS). The loudness, range and peak (−1.94 dBFS, no clipped sample) of the twelve `new-r2` and `new-r3` renders were measured again with `ffmpeg`'s `ebur128` and match the suite's figures.
- **`current` for reference:** −51.4 and −60.6 LUFS on the two quiet excerpts (near-silent), and a worst-10% ending loss of −5.2 to −18.7 dB on the excerpts where G loses −1.2 to −14.4 dB. Excerpt 6 loses about −40 dB with every chain on the isolated audio and none without isolation: that loss is the isolator's.
- **Fallback without a Swift leveler:** `dynaudnorm=f=250:g=51:p=0.9:m=100:b=1` and the K15 compressor (K17 with `makeup=4.26`), no `speechnorm`, no gate. On the isolated audio: −16.5 to −18.0 LUFS on five excerpts and −20.5 on excerpt 3, endings within 2 dB of G. Without isolation, after the existing front filters: −15.3 to −18.9 LUFS, endings better than the production `filterChain` on the five measurable excerpts, but the noise in pauses rises with the speech (−19 to −34 dBFS). `m=10` (the first attempt) left −24 to −42 LUFS; `m=40` equals `m=100` on normal excerpts and leaves the quiet ones 3 to 4 LU lower. Not measured: a pause of several minutes without isolation, where `dynaudnorm` can raise room noise by up to 40 dB.
- **Seams:** forward play after a seek has a 0.000 dB step with the previous piece's 12 s as history. A backward seek into a cached piece steps by 2.5 dB (median) and up to 40 dB across a level change; the fix (re-levelling a piece rendered without history once its predecessor is available) belongs to the production change. Ramps were dropped.

Not established by these numbers: whether words sound whole, and whether short noises that survive isolation (a cough, a knock) are annoying once lifted with the voice. A person listening to the `listening` files decides both.

### Enhanced audio: "Voce livellata" (round 4)

Same suite and gate (`KeypointLevelerRound4.swift`); the six excerpts are the round-3 ones and three whole lectures (91 to 104 minutes) appear only as an index. Question: can a mode without Apple's isolation in what is heard follow the voice's level without lifting the room?

S ("sidechain"): the isolated audio is only a detector. Its keypoint gains (the same leveler as G) are applied to the original audio, under the local ceiling computed on the original, then a front end, K17 and the limiter. Fronts: S-a and S-c put `afftdn` before the equalizers, S-b is the production front (high-pass, low-pass, the two equalizers), S-d cleans the original before the gain.

- `sidechain` (`SIDE`): the four S fronts against G with K17 and against the round-3 chain without isolation (`front + D3-m100`, `dynaudnorm` with `m=100`), per excerpt. Columns as `limiterLoad` and `fallback`, plus `pause noise`: the RMS of the output over the stretches where the isolated audio is silent.
- `longPause` (`PAUSE`): a composite with 180 s of the excerpt's own room noise in the middle, to see what each chain does to a pause of minutes.
- `lectureProfile` (`PROF`, `KEY`): over a whole lecture, the keypoint gains and the level of the levelled original in pause frames and in speech spans, for the plain detector (`BASE`: a frame is voiced above −95 dBFS, a window is measured with at least 15% voiced frames) and three stricter ones (`R`, `E`, `RE`).
- `listening4`: writes `<n>-<label>__original-loud|new-isolated|new-levelled.wav` to `BEEPBAR_AUDIO_AB_OUT`.

Results (Apple M5, 32 GB, debug build, commits `d74ede4` and `a3ebdb5`; one run each, the chains are deterministic):

- **"Voce livellata" is S-b.** Against G with K17 (what "Voce isolata" plays):

  | Excerpt | G LUFS | G limiter p99 / max (dB) | G endings, worst 10% (dB) | G pause noise (dBFS) | S-b LUFS | S-b limiter p99 / max (dB) | S-b endings, worst 10% (dB) | S-b pause noise (dBFS) |
  |---|---|---|---|---|---|---|---|---|
  | 1 quiet, steady | −16.9 | 1.0 / 3.5 | −1.1 | −55.3 | −16.8 | 0.7 / 3.5 | −1.0 | −38.9 |
  | 2 loud, level change | −16.3 | 1.6 / 4.0 | −3.7 | −57.8 | −16.3 | 1.4 / 4.5 | −0.3 | −35.0 |
  | 3 quiet body | −18.1 | 0.0 / 1.1 | n/a | −48.2 | −16.9 | 0.0 / 2.5 | n/a | −25.2 |
  | 4 loud then quiet | −16.9 | 0.0 / 1.8 | −2.4 | −70.2 | −16.8 | 0.0 / 7.3 | −1.8 | −24.7 |
  | 5 normal | −17.2 | 0.4 / 3.7 | −13.0 | −93.0 | −15.8 | 0.6 / 3.8 | 0.6 | −39.3 |
  | 6 normal | −16.7 | 0.0 / 2.6 | −37.3 | −88.0 | −15.0 | 0.4 / 3.0 | 1.2 | −33.1 |

  S-b keeps the word endings that isolation itself removes on excerpts 5 and 6 (nothing after the isolator restores them), at the price of the room in the pauses: 17 to 55 dB more than G. The limiter reaches 7.3 dB once on excerpt 4 (p99 0.0).
- **Rejected fronts.** `afftdn` before the equalizers (S-a, S-c) changes the pause noise by at most 2 dB and costs endings on excerpt 2 (worst 10% −6.5 dB against −0.3). Cleaning before the gain (S-d) lowers the pause noise by 7 dB on excerpt 1 only, with the same loss of endings.
- **Rejected: `dynaudnorm` without isolation.** It follows whatever is loudest, so in a long pause of a normal-level lecture it raises the room by 42 dB (excerpt 5: −70.3 to −28.3 dBFS), where S-b holds its gain because the detector hears silence (−58.2 dBFS). Its endings on excerpt 2 are also worse (−6.8 dB).
- **A long pause can still raise the gain.** In the composite of excerpt 2 the isolated room noise is not silent, the detector reads it as voice and the gain goes from 2.6 to 46.6 dB during the pause (pause at −18 dBFS). Over whole lectures this is rare: the levelled original in pause frames stays at p90 −46.7, −29.4 and −46.0 dBFS on the three lectures, above −26 dBFS for 2 s, 60 s and 4 s of 22, 42 and 10 minutes of pauses.
- **The detector stays plain.** The stricter detectors change those figures little (lecture 2 with `RE`: p90 −31.5 dBFS, 37 s above −26) and lose speech: six 10-second speech spans end below −30 dBFS on lecture 2, none with `BASE`.
- **Known limit.** Lecture 2 has speech near −64 dBFS and about 14 dB between voice and room: its gain is 44.5 dB (median), so the room in its pauses plays at about −33 dBFS (median) in "Voce livellata", above −35 dBFS for 27 of 42 minutes of pauses. "Voce isolata" is the mode for such a lecture.

Not established by these numbers: which mode a listener prefers on a given lecture. A person listening to the `listening4` files decides.

### Enhanced audio: production leveler

`VoiceLeveler` (Core) replaces the prototype in the pipeline; the prototype stays in the test target as the reference these rounds measured. `VoiceLevelerReferenceTests` proves that a lecture played forward in 30-second segments, each levelled from its own clip with the session's keypoint memo, equals the prototype over the whole lecture (within 0.01 dB of gain), and that a segment made after a seek leaves no step at its seams.

Preparation time per part, with the harness of "Enhanced audio (live filter)" above (`BEEPBAR_MEASURE_AUDIO=1 swift test --skip-build --filter LiveAudioMeasurements` after `swift build --build-tests`; Apple M5, 32 GB, debug build, AC power; five runs per commit, interleaved; `dev` is `46bd452`, the branch `a0129e9`). Wait in ms, median / p95 (with five runs the p95 is the maximum):

| Variant | First part (`seg0`) | Seek ahead (`seg8`) | Back to a part already heard (`seg1`) |
|---|---|---|---|
| `dev`, isolation (the chain this replaces) | 1096 / 1203 | 1055 / 1084 | 344 / 347 |
| branch, `.isolated` | 1176 / 1180 | 1161 / 1163 | 438 / 441 |
| branch, `.levelled` | 1253 / 1257 | 1289 / 1304 | 473 / 480 |
| `dev`, ffmpeg only | 614 / 630 | 637 / 641 | 644 / 648 |
| branch, ffmpeg only | 614 / 619 | 636 / 638 | 638 / 660 |

Against `dev`, a part not heard yet waits 80 to 110 ms more in `.isolated` and 160 to 235 ms more in `.levelled` (which also decodes and keeps the original audio); a part already heard waits about 95 and 130 ms more, because the pieces stay raw on disk and each segment is levelled when it is encoded. The path without isolation is unchanged. On the final commit `cdc7631` the levelling reads 10 s more of the next piece (20.5 s instead of 10.5, so that a segment ending just past a multiple of 10 s still sees the keypoint after its last one); two runs of the same harness gave, in ms, `.isolated` 1198 and 1194 (`seg0`), 1205 and 1203 (`seg8`), 452 and 432 (`seg1`), and `.levelled` 1288 and 1303, 1330 and 1369, 560 and 497. Not measured: a Release build, a machine with less memory, and `main` (enhanced audio has never been released, so there is no released behaviour to compare with).
