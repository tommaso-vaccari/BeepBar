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

Normal gates are `swift test` and the CI `xcodebuild ... Release ... CODE_SIGNING_ALLOWED=NO`.
This host has Command Line Tools without Xcode: `xcodebuild` rejects the active developer
directory. Both normal SwiftPM and native builds of the full app fail because the SDK references
`SwiftUIMacros` while its plugin is absent. Adding the bundled Testing macro plugin does not
resolve the missing SwiftUI plugin. No full-suite/Release-app success is claimed locally.

Targeted fallback is reproducible with:

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
swift build --build-system native --target BeepbarCore -c release
```

The fallback copies unchanged Core and recordings controller/session/browser/scripts into a
temporary package, uses the same controller suite (excluding real-account-controller integration)
and store suite, and substitutes only app-global fixture settings providers. The mutation restores
a global 5,000-row eviction in that disposable copy; regressions must fail. It does not touch the
working checkout, installed app, user preferences or real account. This fallback does not replace
full CI. Live Polimi, app-wide responsiveness, power-loss durability and base-dev/main UI timing
comparisons remain unmeasured.

Historical checkpoint `30c7f14` validation before its rejected independent review: targeted copied implementation is green with
40 tests in two suites (0.247 s runtime). Controlled global-cap mutation is red: two selected
regressions produce six issues, including old recordings becoming New after cross-course/relaunch
and disappearance/reappearance. The original source was unchanged by the mutation. Final Core
Release compilation passed (11.76 s). Disk probe passed separately (one instrumentation test).
`git diff --check` is clean. Full-suite/App Release/online CI remain outstanding because of the
local toolchain limits above; judge review and any follow-up fixes must precede pushing/opening PR.

Review iteration (not yet approved): actor execution, reset tombstone, paired snapshots and removal
of the aggregate address the four review findings. Additional regressions guard acknowledgement
revisions, close/reopen, duplicate-click coalescing and nonrecursive cleanup. Initial Xcode targeted
runs passed; final full-suite/Release results and controlled mutation results are recorded against
the exact next checkpoint in issue #106 before its second independent review. The earlier CLT
limitation is historical; the installed Xcode now supports the standard gates without any license
acceptance action by this task. No installed app was signed, launched or replaced.
