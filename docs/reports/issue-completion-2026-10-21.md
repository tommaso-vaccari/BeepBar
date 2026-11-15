# Issue completion — 2026-10-21, PR #232

Base dev: `770260a7d245f0f069f0e6636f5423b00bd15fe9`. Final validation and merge SHAs are recorded in PR #232.

## Activity #99

The inner stack now constructs revealed rows lazily, including after Show more has revealed all 15,000 entries. Pagination, row IDs, actions and accessibility labels are unchanged. A hidden hosted regression checks first/last reachability and fewer than 200 unique row constructions initially / 400 after jumping to the end; reverting the inner stack to eager construction must fail. Existing ActivityRowLayout and Activity action tests remain part of the full gate.

Before implementation, `python3 scripts/ui-benchmark.py --ref origin/dev --out PerformanceReports/issue99-base-dev-20261021 --scenarios activity-1000 activity-15000 --runs 5 --warmup 1` ran on Apple M2, 8 GB, AC power. Raw series/traces remain in that local ignored report directory. First expanded-content median/max: 1,000 rows 128.656/130.641 ms; 15,000 rows 135.059/159.401 ms. Window-key median/max: 280.600/285.997 and 294.093/344.665 ms respectively, exceeding the 250 ms window target. These are five samples, not reliable p95 estimates, and reveal only the first 200 rows.

Further foreground app launches were stopped at the owner's request. Hidden hosted tests establish construction bounds and reachability, not compositor/frame-time guarantees. Candidate/base-dev and candidate/main timing comparisons and the 16 ms scrolling budget remain unmeasured. Do not close #99 on the strength of this structural fix alone or describe its performance acceptance as passed.

### Resumed Activity acceptance

The owner subsequently authorized foreground synthetic benchmarks. Work continues in
`perf/activity-99-acceptance`, based on integrated dev `7ad62a2`. The local ignored
`PerformanceReports/activity-99-base` series contains five measured processes plus a warm-up
per corpus on the current Mac17,3 / 32 GB machine, AC power. Initial-page key median/max is
111.981/114.768 ms (1,000) and 116.873/120.787 ms (15,000). These measurements are not a
comparison with the earlier M2 / 8 GB machine.

`PerformanceReports/activity-99-scroll-all` at `3cf30ef` reveals the complete corpus and
performs 240 display-link callbacks per process. All five 1,000-row processes exceed the
16 ms synchronous-work budget at the explicit jump to the last row (22.034–23.302 ms maxima);
the 15,000-row processes also exceed it (21.539–22.596 ms). Ordinary steps have lower maxima,
but excluding the jump would hide a repeatable failure. Display-link delivery intervals and
synchronous work remain separate signals; neither proves compositor presentation.

The first intrinsic-height layout experiment at `68c5af9` was invalid:
the screen was locked and the fixture could not become active. The driver now rejects locked
or unknown console state and requires fixture frame-update evidence from Hitches during the
single measured scroll interval. Source correction, final comparisons and performance
acceptance remain pending; #99 remains open.

After the owner unlocked the console, `activity-99-intrinsic-unlocked` completed one warm-up
and one measured process per corpus at `68c5af9`: synchronous scroll maxima were 19.794 ms
(1,000) and 20.329 ms (15,000). Five unprofiled processes plus a warm-up at the same source
(`activity-99-intrinsic-unprofiled`) also fail the 16 ms budget: measured maxima
19.651–21.177 ms and 18.970–22.430 ms respectively. Profiling overhead does not explain the
failure. These series are separate; the unprofiled one has no trace or presentation evidence.

Some Hitches exports contain positive-duration fixture rows with start time zero and no
matching update. Their timing origin is unresolved; clipping such rows would falsely report
an interval-long hitch. The validator now reports `scrollHitches.valid: false`, retains the
anomalies, and omits hitch-count/duration verdicts. This does not turn the synchronous-work
failure into a pass. Raw traces remain retained.

A hosted accessibility regression at `dea9b4d` passes with 1,000/15,000 rows and 480/1,000-point
windows, long filenames, actual Show more presses (three/seven), and first/last viewport
geometry. The PDF opens through the injected opener and the final script reveals in Finder;
labels, hints and absence of item problems are checked against an isolated synthetic database.
This is hosted UI/AX evidence, not compositor presentation. Layout experiments and final
comparisons remain in progress; #99 is still open.

### Final comparisons at `b612bd2` (2026-10-28)

Machine: Mac17,3, 32 GB, macOS 27.2 (26B123), Xcode 27.1, AC power, console unlocked. Every
series ran five measured processes plus one warm-up per corpus. Medians and maxima are
reported; five samples give no reliable p95. Raw reports remain in the local ignored
`PerformanceReports/` directories named below.

**Scroll, before → after this branch's row changes.** `3cf30ef` contains the scroll seam
without the row layout changes. Before `68c5af9` the harness also emits `ui.fixtureActivityScroll` around a
different interval, so the current profiled driver rejects its traces. Both refs were therefore
measured unprofiled with identical flags (`--scroll-all --unprofiled`,
`activity-99-unprof-3cf30ef` / `activity-99-unprof-b612bd2`). Synchronous callback work, ms:

| Corpus | Phase | `3cf30ef` median / max | `b612bd2` median / max |
|---|---|---:|---:|
| 1,000 | jump to last row (callback 120) | 21.77 / 22.45 | 16.80 / 17.68 |
| 1,000 | continuous 48-pt steps, per-run max | 6.00 / 6.12 | 4.74 / 5.52 |
| 15,000 | jump to last row (callback 120) | 20.75 / 21.37 | 16.93 / 17.85 |
| 15,000 | continuous 48-pt steps, per-run max | 5.62 / 5.67 | 4.53 / 5.26 |

The per-run display-link delivery maximum falls from 28.8–31.2 ms to 24.6–26.4 ms. Both
revisions still miss one frame at the jump.

**Profiled candidate** (`activity-99-scroll-b612bd2`). The worst synchronous frame in each of the
ten measured processes is callback 120, at 15.37–16.94 ms. Instruments records exactly one
16.67 ms fixture hitch per process; its timestamp falls in the frame after that callback, and
`scrollHitches.valid` is true. Continuous steps peak at 4.2–5.4 ms. Time Profiler samples in
that frame are spread over SwiftUI lazy-layout construction and sizing of the newly visible rows
(`_LazyLayout_Subviews.applyNodes`, `_FixedSizeLayout.sizeThatFits`). No single app-side cost
dominates. The jump cost is the same at 1,000 and 15,000 rows, so it is bounded by the
viewport, not by corpus size.

In two of the five profiled 15,000-row processes, one display-link interval near callback 10
reached 21.9/22.7 ms, while the work inside the callback was about 4 ms. Work outside the
callback is not captured by the synchronous measure. Instruments did not report it as a hitch.

**Opening, base dev and main** (`activity-99-open-7ad62a2`, `activity-99-open-07fba3b`, profiled,
without `--scroll-all`; scrolling is unmeasured on both because they lack the seam). Medians, ms:

| Corpus | Metric | main `07fba3b` | base dev `7ad62a2` | candidate `b612bd2` |
|---|---|---:|---:|---:|
| 1,000 | window key | 248.7 (max 252.4) | 90.1 | 86.5 |
| 1,000 | first expanded Activity | 122.0 | 32.1 | 30.2 |
| 15,000 | window key | 247.1 (max 255.9) | 87.4 | 82.8 |
| 15,000 | first expanded Activity | 122.3 | 31.7 | 31.7 |

Main exceeds the 250 ms window target at its maximum. Against main, the candidate opens the window
about 2.9× faster and shows the expanded content about 4× faster; most of this came from the
work already integrated in dev. Against base dev, opening is unchanged within noise.

**Decision.** The candidate cuts the jump frame by 18–23% and continuous work by about 20%.
It does not meet the 16 ms main-thread budget: the jump to the last row still reaches
16.8–17.9 ms unprofiled. That jump is a real user flow (End key, dragging the scroller), so it is
not excluded. The remaining cost is SwiftUI construction of one viewport of rows. #99 stays
open. Further reduction needs either cheaper rows, for example an AppKit-backed table, or a
product decision on this residual. This report does not claim that either outcome has been
achieved.

Enabled interactive rows are not measured. The fixture disables all of its controls in every
scenario, so hover tracking and pointer-style costs are excluded and the jump numbers may
understate the cost of enabled rows. Manual scrolling and actions remain required.

### Owner decision (2026-11-15)

This supersedes every earlier statement in this report that #99 remains open or must not be
closed. The "continuous 48-pt steps" figures above exclude the explicit jump (callback 120) by
hand; the driver's own per-run maximum includes it.

1. The realistic worst case for the Activity page is **1,000 files** in one expanded course.
   Acceptance tests and documented benchmark commands for #99 use 1,000. The 15,000 measurements
   above stay as history, not as a criterion; `activity-15000` remains a stress scenario.
2. The owner **accepts the residual** on the 16 ms main-thread budget: the explicit jump to the
   last row costs one frame of 16.80 ms median / 17.68 ms max (1,000 rows, unprofiled, five runs
   plus one warm-up, `b612bd2`, Mac17,3 / 32 GB, AC power). Continuous scrolling peaks at 4.74
   median / 5.52 max ms. The residual is SwiftUI construction of one viewport of rows, independent
   of corpus size; reducing it further would need an AppKit-backed table, judged not worth it. The
   exception covers only that frame, as measured, on that machine. The budget is otherwise unchanged.
3. **Not measured:** the final HEAD of PR #249 (it also contains dev up to `967353d`, which did not
   touch `ActivityPage.swift`; the owner decided against a confirmation series), the earlier
   reference machine (Apple M2 / 8 GB) for scrolling, enabled interactive rows (hover), p95 (five
   samples), and compositor presentation. Base-dev -> HEAD and main -> HEAD opening comparisons
   exist only as recorded at `b612bd2` against `7ad62a2` / `07fba3b` (1,000 rows: window key main
   248.7 ms, base dev 90.1, candidate 86.5; first expanded Activity 122.0 / 32.1 / 30.2).
4. #99 closes with PR #249 (scroll measurement, row-layout simplification, hosted accessibility
   regression), on top of the lazy rows delivered by PR #232.

## Tooling #222

The shared gate now executes the isolated recordings fixture; repairing its extracted debug probe dependency demonstrates the previously untested dependency rot. The extraction checks its source anchor and copies only the needed bulk-scan declaration. The fixture passes 142 tests. UI benchmark and Linux-wrapper regression suites already belong to the gate and remain enabled. Mutation switches intentionally expect failing tests and are not normal green gate invocations.

The wrapper regression clears inherited Git repository environment variables before creating disposable repositories. Both normal and simulated hook-environment runs pass all ten lockfile/signal cases, preserving the caller repository. Linux Core now has a release-PR-only job using digest-pinned Swift 6.2.1 Jammy and explicit SQLite development headers. No development CI or manual release job is triggered. Actual Linux execution awaits the next authorized dev → main PR; this delivery establishes coverage configuration, not a claim that this new online job has already passed.

## Released privacy record #180

Release [v3.0.0](https://github.com/tommaso-vaccari/BeepBar/releases/tag/v3.0.0), published 2026-10-19, points to `07fba3b647577ec08f17e486004129dd5f81357a`. Downloaded `00-Beepbar.dmg`: 6,050,863 bytes, SHA-256 `eb7605865f9cf3dfa6595b7943313398bbf3a60dc4b67c62cae99140d6e2ad8f`, matching GitHub's asset digest. Its arm64 app identifies version 3.0.0 and `io.github.tvaccari.beepbar`; `codesign --verify --deep --strict` passes. This verifies its existing signature, not notarization or an independently attested publisher identity.

Bundled `Contents/Resources/privacy-notice.md` matches both notice copies in tag v3.0.0 byte for byte: SHA-256 `a607a3381c15d5f38d2486b3affc1326850dd6931ffc8b180172387220757bca`. Current main has no difference in these notice copies or Telemetry.swift. The public [BeepBar page](https://www.tommasovaccari.com/beepbar) already links to the main-branch notice. The appcast enclosure identifies the same 3.0.0 asset and byte count and includes an Ed25519 signature; this inspection does not independently verify that Sparkle signature. No installed app was launched, installed or changed for these checks.

This completes the outstanding released-artifact/notice record. Existing qualified v2 assessment and opt-out remain unchanged. Historical UUID events have not been erased or retrospectively validated; no cold-event deletion schedule is assumed. Previously waived packaged-app network/session/backup/erasure manual checks and procedure dry run remain unperformed. No full-app GDPR certification follows. Reassessment triggers and annual review remain in the privacy gate.

## Previously closed work and tracker

#162 and #217 were closed after their issue-specific evidence reconciliation earlier in this delivery. Collaborator tommasoz24 closed #107, #115 and #116 on 2026-10-21. Those state changes are preserved; no new playback scheduling measurements or real-account validation matrix were produced here, and their historical evidence gaps are not relabeled as passing checks. The tracker must keep #99 visibly outstanding even if its own closed state is retained.
