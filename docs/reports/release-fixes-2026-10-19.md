# Release review fixes — 2026-10-19

Scope: local `dev` working tree based on `26edaf0f2d2fca29deaf4eb46227c59d1e606efc`. No commit or push has been made. The [source manifest](release-fixes-2026-10-19/source-sha256.json) identifies the tested files. Temporary validation snapshot `67e17fe7705e9195cf132ce9722b9164f5fd699b` is a disposable-copy commit, not a published dev revision.

## Changes and acceptance evidence

| Item | Change | Verification |
| --- | --- | --- |
| #183 | Retry recovery completes pending course-folder renames, reloads committed folder names before resuming sync, and preserves the current account. Failed recovery stays blocked. | Regressions cover interrupted and automatic renames, partially completed recovery followed by retry or abandon, blocked bootstrap and sign-in during recovery. |
| #185 | Remove the redundant hash of the staged hard link after verifying file identity. Initial and final source hashes and concurrent-write protection remain. | The 8 MiB fixture now hashes 16 MiB instead of 24 MiB; cancellation and concurrent-write tests pass. No elapsed-time improvement is claimed. |
| REL-FINAL-01 | Changelog explains that reporting may start immediately after Close and opt-out is in Settings. | Compared with the integrated notice flow; bundled and documented notices are byte-identical. |
| #205 | Old `1f413db` UI results remain explicitly historical; current synthetic measurements are recorded separately below. | Warm reopen is not inferred from first-window results. |
| #206 | Mark missing historical raw logs/series as unavailable in the performance plan and recordings reports. Retain current verification data and source hashes here. | No historical raw samples were reconstructed from published medians. Lost evidence remains lost. |
| #216 | `.mailmap` maps the historical automated author identity to the owner. | `git check-mailmap` resolves the mapping. Existing commit objects and raw author fields are unchanged. |

## Validation

- Full suite: **1,549 passed** (16 XCTest, 649 Core, 31 benchmark, 853 app).
- CI-equivalent Release build passed; arm64, plist, assets, embedded Sparkle and packaged privacy notice checks passed. Local ad-hoc signature verification passed; this is not the distribution signature.
- Tooling passed: 11 benchmark comparison tests, 13 UI-driver tests, 10 Linux-wrapper cases, release-note and build-version checks.
- Independent final code review found no remaining actionable P0/P1/P2 within the changed scope.
- Both controlled mutations failed assertions without compilation errors: restoring the third Trash read, and suppressing recovered folder-name publication. Restoring source made the regression suite pass. See [mutation results](release-fixes-2026-10-19/mutation-results.json).
- Structured validation summary: [verification.json](release-fixes-2026-10-19/verification.json).

## Release status

The owner attested on 2026-10-19 that every original PR #150 manual check was personally executed successfully. That historical attestation is preserved; it does not represent a new manual run of these local changes. The changed recovery paths have synthetic regression coverage.

Published CI runs `39303299825` and `39303293696` passed on `26edaf0`; they do not cover this uncommitted delta. Commit/push and green integration on the resulting dev SHA are still required before a merge recommendation for these fixes.

The aggregate-v2 privacy assessment is favorable and qualified as documented in `docs/privacy-release-gate.md`; obsolete monthly-UUID objections do not describe current code. The final signed/versioned release artifact must still match its notice/configuration, and the owner maintains the matching website notice at release. These checks cannot be claimed complete on a local unsigned build. No installed app, live account or website was changed.

## Current UI measurement attempt

The isolated Release-arm64 fixture built successfully on Mac17,3 / 32 GiB, macOS 27.0.1, Xcode 27.1, AC power. The `recordings-1000` warm-up failed with `missingContent`; its log reports the window below a system shield. The driver correctly marked the series invalid and stopped before measured samples or `launch-warm`. No current latency, warm-reopen budget or performance improvement is established. This first attempt was superseded by the valid unlocked-session rerun below. [Retained attempt metadata](release-fixes-2026-10-19/ui-attempt.json); original logs/traces remain locally under ignored `PerformanceReports/release-2026-10-19`.

### Valid unlocked-session rerun

After the owner unlocked the session, both scenarios completed five measured samples plus one warm-up, including successful required Time Profiler/signpost trace validation. [Retained raw numeric samples and metadata](release-fixes-2026-10-19/ui-series.json), [timing table](release-fixes-2026-10-19/ui-series.md). Same source manifest and temporary snapshot as tests/build.

| Scenario | Median window key | Maximum window key | Target |
| --- | ---: | ---: | ---: |
| 1,000 recordings, first window | 100.630 ms | 103.052 ms | 250 ms |
| Same-process warm reopen | 64.118 ms | 65.303 ms | 100 ms |

First recording-content median is 190.947 ms; warm course-content median is 31.965 ms. Content means SwiftUI onAppear, not compositor presentation. All observed window samples met the targets. Five samples do not establish reliable p95, scrolling smoothness, every 16 ms stall, production bootstrap or performance gains against main/dev; those remain unmeasured. No idle or memory-cycle scenario was run in this focused series. Full local traces are retained for further interpretation. This resolves the missing current-source/warm measurement for the local fixes, but final source identity must still be tied to the published commit before release.

### CI preference-fixture follow-up

On `ff6d26125a006d36ae1e3bcae8c0ff799c4aeb32`, [run 39308990563](https://github.com/tommaso-vaccari/BeepBar/actions/runs/39308990563) failed with 19 preference-state assertions across notification, telemetry and recordings-menu tests, while [run 39308997853](https://github.com/tommaso-vaccari/BeepBar/actions/runs/39308997853) passed on the same commit. The 79 affected tests also passed locally before the change; the intermittent failure was not reproduced locally.

The behavioral fixtures now reuse the existing in-memory defaults double, removing their dependence on asynchronous disk preferences. Notification callbacks share that fixture rather than reopening a disk suite. Assertions and production code are unchanged. Real disk persistence and second-handle visibility remain covered by `ThrowawayDefaultsTests`. Independent review found no blocking issues. The earlier source manifest describes the earlier candidate and is not a manifest of this test-fixture follow-up.

Validation of this follow-up: full local `swift test` passed (16 XCTest, 649 core, 31 benchmark and 853 app tests; 1,549 total), and the CI-equivalent Release build passed. Online CI must pass on the resulting published commit before release.

The first fixture follow-up (`1dd85c8`) passed locally with Xcode 27.1 but failed to compile on the CI toolchain: capturing `MemoryCountingDefaults` in the notification fake's nonisolated `@Sendable` hooks was rejected. Both hooks are now explicitly `@MainActor @Sendable` and awaited, matching the coordinator/tests' isolation while preserving their before-read-answer and after-send ordering. Independent re-review found no blocking issue; the CI-toolchain compilation still requires online validation.
