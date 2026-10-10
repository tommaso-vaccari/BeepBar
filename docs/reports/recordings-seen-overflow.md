# Recording history beyond 5,000 IDs — #106

Base: `origin/dev` `ac68333`, branch `fix/recordings-seen-overflow`. Historical finding
rechecked: v1 drops old IDs from a shared 5,000-element acknowledgement list, while each
course/year baseline remains. A 5,001st existing ID therefore becomes “New”, and acknowledging
another course can make the first one's old IDs new again.

## Representation and migration

`recordings-seen-v2.sqlite` has indexed, account/course/year/ID primary keys. A complete first
listing atomically creates its baseline plus all IDs. Later listings query membership only for
current IDs; opening or “Mark as seen” inserts acknowledgements. Dates are never checkpoints:
old lecture dates and out-of-order publication remain new if their ID has not been acknowledged.
Duplicate insertions do not rewrite rows. SQLite uses FULL synchronization, rollback journaling,
a 2 MiB page cache, a private 0600 file and 0700 folder. The synchronous SQLite primitives execute on a serial history actor, including migration,
lookups, writes and cleanup. The controller validates account/namespace after each await and
also generation for listing results. `isNew` reads only the successfully published listing's
membership snapshot; it performs no disk lookup. Listings and membership are published together,
and a failed history read retains the prior pair (or shows the error without a first list).
No process-wide aggregate set is constructed. The complete history is not loaded into RAM,
but displayed listings and per-list seen-ID snapshots still scale with courses visited in the
current process. D07 remains necessary before claiming app-wide UI latency results.

v1 survivors are imported once in a transaction, together with existing course/year baselines.
Their original scope was not stored; the small legacy survivor index is consulted only for
migrated baselines. New scopes use exact scoped membership. Preferences are removed only after
successful import, and failure preserves migration input for retry. A saved session must verify
the v1 owner's identity; without it, unowned v1 history is discarded rather than assigned to the
next student. IDs v1 already evicted cannot be reconstructed with certainty. Such recordings
remain New until opened/marked seen; this policy never silently labels a genuinely new ID old.

History is retained even if a recording disappears, a course is deselected, or the academic year
changes. Automatic eviction cannot be exact without additional server guarantees. Disk cost is
linear in unique acknowledged IDs plus SQLite indexes/pages; repeated unchanged listings add no
history. With synthetic 32-character IDs, this host measured 299,008 bytes for 5,001 IDs
and 581,632 bytes for 10,000 IDs (about 58 bytes per ID, including database tables/pages).
One Debug sample measured a 10,000-ID baseline at 15.3 ms and membership lookup at 52.5 ms.
This measurement was from checkpoint `30c7f14`, whose synchronous main-actor lookup could block
UI. Independent review rejected that design; the revised history actor executes the same work
off the main actor. These are uncontrolled single samples, not p95 measurements or before/after
UI comparisons. Executor placement is covered by actual I/O thread probes and held-operation
lifecycle fixtures, rather than inferred from the raw operation duration. Disabling Recordings, disconnecting or changing account synchronously persists a new opaque UUID
namespace in the preferences and invalidates the previous worker. The old worker then removes its
database/sidecars, serialized after in-flight work. New namespace operations await this cleanup
barrier. If removal fails, the tombstone prevents same-account re-enable/relaunch from reusing old
baselines, and obsolete files are retried on subsequent history work. Only this opaque UUID remains
when the feature is off; it contains no account or recording IDs. Failed removals may leave obsolete
disk data until permissions/storage recover. A storage error is reported rather than publishing
a false durable baseline. Explicit acknowledgements continue across page closure for the same
account/namespace; account reset rejects them, and listing results from stale generations cannot
return. A per-course acknowledgement revision makes a delayed read requery if a newer acknowledgement
was published while the read returned.

## Validation and limits

Relevant fixtures cover 5,010 recordings plus 3,000 in another course, first listing, “Mark as
seen”, relaunch, disappearance/reappearance, out-of-order dates, v1 survivors/missing IDs,
unknown ownership, corrupt database/retry, identity/year isolation, duplicate insertion,
empty baselines, file permissions, reset and transaction rollback on a midway insert failure.
Review follow-ups add worker-thread execution probes, a held history read during page close,
transient failure with an existing list, cleanup denial across re-enable/relaunch, held
acknowledgement after reset, acknowledgement across close/reopen, and delayed read versus newer
acknowledgement. Repeated clicks coalesce IDs already pending so slow storage does not retain
one duplicate task/list per click. Cleanup uses unlink and never recursively removes a directory
unexpectedly replacing a database file.

### Current verified implementation: `378175a`

The actor/reset/snapshot revision is commit
`378175a9ef3c19e12db235747f03255540171451`. Standard gates passed on that exact commit
with **Xcode 27.0, build 27A266a**, selected at `/Applications/Xcode.app/Contents/Developer`.
The previous Command Line Tools limitation was resolved before these runs. The working tree
was clean and `git diff --check` passed. No installed app was signed, launched or replaced,
and this task performed no license-acceptance action.

| Command | Result on `378175a` | Exact local log |
|---|---|---|
| `swift test` | PASS: 362 Core + 27 Benchmark + 268 App Swift Testing tests, plus 14 XCTest tests = **671 total**, zero failures | `/tmp/issue106-full-378175a.log` |
| `xcodebuild -project Beepbar.xcodeproj -target Beepbar -configuration Release -clonedSourcePackagesDirPath build/SourcePackages build CODE_SIGNING_ALLOWED=NO` | **BUILD SUCCEEDED**, signing disabled | `/tmp/issue106-release-378175a.log` |

The full-suite log records these final summaries:

```text
Executed 14 tests, with 0 failures (0 unexpected)
Test run with 362 tests in 38 suites passed after 18.477 seconds.
Test run with 27 tests in 4 suites passed after 2.212 seconds.
Test run with 268 tests in 30 suites passed after 12.440 seconds.
```

Controlled mutations below were made only in a disposable source copy of `378175a`.
Every mutant compiled, ran its regression and returned nonzero; none is a compilation failure.
Restoring the original source passed **49 targeted tests in two suites**, with zero failures
(0.328 s runtime), logged at `/tmp/issue106-actor-restored-green.log`.

| Removed guarantee | Regression result | Exact local log |
|---|---|---|
| History executor moved to main actor | Red: one test, one issue | `/tmp/issue106-mutation-main-actor.log` |
| Persisted reset namespace | Red: one test, six issues | `/tmp/issue106-mutation-reset.log` |
| Keep the previous list when history read fails | Red: one test, two issues | `/tmp/issue106-mutation-snapshot.log` |
| Acknowledgement revision validation | Red: one test, one issue | `/tmp/issue106-mutation-revision.log` |
| Exact history, with global 5,000-ID cap restored | Red: two tests, seven issues | `/tmp/issue106-mutation-cap.log` |
| Duplicate-click coalescing | Red: one test, two issues | `/tmp/issue106-mutation-coalescing.log` |
| Nonrecursive cleanup, with recursive removal restored | Red: one test, two issues | `/tmp/issue106-mutation-cleanup-kind.log` |

These results address the first independent review's four code findings: synchronous main-actor
I/O, reset after deletion failure, mismatched list/history snapshots, and the duplicated global
aggregate. Subsequent code review requested only this report's historical/current gate correction.
That documentation-only correction does not alter the verified implementation above or claim a
new test run on its documentation commit. Independent approval and online PR CI remain pending;
the **local full suite and Release app build have passed**.

### Historical environment: checkpoint `30c7f14`

At the earlier commit `30c7f144a1231bb9949fddb8110b52e78db5c4fb`, this host had only Command
Line Tools, without Xcode. At that time `xcodebuild` rejected the active developer directory,
and full app compilation failed because the SDK referenced a missing `SwiftUIMacros` plugin.
Adding the bundled Testing macro plugin did not fix SwiftUI compilation. Those failures describe
only the earlier checkpoint; they are **not current blockers** and are not failures of the
verified `378175a` gates above.

The targeted fallback then passed 40 tests in two suites (0.247 s runtime); restoring the global
cap produced two failing regressions and six issues. Core Release compilation passed (11.76 s),
and the synthetic disk probe passed separately. The synchronous main-actor lookup measured
52.5 ms in Debug, and independent review rejected that implementation. The actor/reset/snapshot
revision above replaced it before the successful standard Xcode gates.

### Reproduction and remaining limits

The isolated fixture and controlled mutations remain reproducible on the current source:

```sh
python3 scripts/recordings-seen-isolated-tests.py
python3 scripts/recordings-seen-isolated-tests.py --mutate-cap  # expected nonzero
python3 scripts/recordings-seen-isolated-tests.py --mutate-main-actor  # expected nonzero
python3 scripts/recordings-seen-isolated-tests.py --mutate-reset  # expected nonzero
python3 scripts/recordings-seen-isolated-tests.py --mutate-snapshot  # expected nonzero
python3 scripts/recordings-seen-isolated-tests.py --mutate-revision  # expected nonzero
python3 scripts/recordings-seen-isolated-tests.py --mutate-coalescing  # expected nonzero
python3 scripts/recordings-seen-isolated-tests.py --mutate-cleanup-kind  # expected nonzero
python3 scripts/recordings-seen-isolated-tests.py --probe-disk
```

The fixture copies unchanged Core and recordings controller/session/browser/scripts into a
temporary package, uses the controller suite (excluding real-account-controller integration)
and store suite, and substitutes only app-global fixture settings providers. It does not touch
the working checkout, installed app, user preferences or real account. This fixture is separate
from the successful standard full-suite/Release gates and does not replace online PR CI.
Live Polimi, app-wide responsiveness, power-loss durability and base-dev/main UI timing
comparisons remain unmeasured. The recorded disk/Debug duration samples are the historical
synthetic measurements described above, not a claim of app-wide performance or p95 latency.
