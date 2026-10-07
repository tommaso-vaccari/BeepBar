# Recordings validation — 2026-10-07

Branch: `dev`, reviewed for draft release PR #86 against `main`. Production merge remains gated on local beta testing.

## Automated checks

- `swift test`: 613 tests passed (337 core, 24 benchmark, 238 app Swift Testing, 14 app XCTest), with no known issues. Unchanged course refreshes and sync completion now satisfy the publication-count regressions directly.
- `xcodebuild -project Beepbar.xcodeproj -target Beepbar -configuration Release build CODE_SIGNING_ALLOWED=NO`: succeeded. Existing build-order, Sparkle stripping and AppIntents metadata warnings remain.
- `scripts/quit-probe.sh`: legacy menu and dispatch variants hang as expected; corrected menu and external quit variants exit. This is an isolated AppKit probe, not the installed app.
- `git diff --check`: clean.

## Regression sensitivity

In disposable source copies, each mutation produced test expectation failures, not compilation errors:

| Mutation | Failing test |
| --- | --- |
| Return every course instead of filtering enabled IDs | `sidebarExcludesDisabledCoursesInBothSections` |
| Click the next-page link instead of navigating to its URL | `theNextPageIsLoadedNotClicked` |
| Click the 100-per-page link instead of navigating to its URL | `severalPagesSwitchToAHundredAPage` |
| Remove the fallback for an entirely unsearchable course list | `selectionFallsBackWhenEveryCourseLacksCodeOrYear` |
| Start Sparkle automatically in Debug | `debugBuildDoesNotStartSparkle` |

Presentation coverage also checks title fallback, search, durations, stable chronological numbering, Monday week boundaries across daylight-saving time, empty lists and older year/month ranges.

## Independent review

The first review identified a P2: the detail pane was empty when every synchronized course lacked a code/year. The selection fallback was corrected and tested. The same reviewer re-reviewed the change and reported no remaining actionable findings. No P0 was reported.

The release review found three further issues: an older conflict with identical remote bytes could authorize recovery of a newer revision; a slow recording lookup could supersede a newer Play/Copy choice; and a failed benchmark subprocess could reuse an old successful report. All were corrected with regression coverage. The recovery and recording regressions failed before their fixes, as did the three unchanged-value publication assertions. Independent follow-up review of these fixes and the benchmark subprocess tests reported no remaining actionable findings.

## CI follow-up

The initial CI run exposed a wall-clock assertion in `menuQuitGivesUpWaitingAfterTheTimeout`: the overloaded runner resumed after the two-second threshold. The test now holds a cancellation-resistant sync at a gate and verifies that quit returns before that sync finishes. A 30-second watchdog releases the gate so a regression fails rather than hanging indefinitely. Production quit behavior is unchanged.

## Verification limits

The existing live probe is `scripts/recman-probe.sh cold <course> <year>` followed by `warm`. Real Polimi sign-in, session expiry and playback were not repeated during this completion pass. Browser tests use WebKit fixtures and controller tests use a fake browser; a Release build and passing fixtures do not establish live SSO success.

## Recordings UI follow-up

- Full `swift test`: 614 tests passed (337 core, 24 benchmark, 239 app Swift Testing, 14 app XCTest). The Release build with signing disabled also succeeded.
- All nine presentation tests passed. Returning the unprocessed course name caused four assertions in the new name-formatting regression to fail; restoring the implementation made them pass.
- Offscreen renders checked compact and wide layouts, long titles, visible Play controls, and English/light and Italian/dark appearances. These used an isolated fake browser and preferences, without launching or replacing the installed app.
- Independent review identified a P2 concerning courses with identical readable names. Keeping course code and academic year visible in the sidebar resolved it; the same reviewer reported no remaining actionable findings.

## First-use introduction follow-up

- Without reusable saved cookies, the first page visit shows the existing introduction and sign-in button before creating a browser or fetching recordings. Session checking remains deferred until the page opens; matching saved sessions still load automatically.
- Focused controller/account tests: 36 passed. Removing the production fix caused six failures in the first-use regression; restoring it made the focused suite pass again.
- Full `swift test`: 618 tests passed (337 core, 24 benchmark, 243 app Swift Testing, 14 app XCTest). The unsigned Release build and `git diff --check` passed.
- Independent Sol 6.1 medium review reported no actionable findings. Coverage includes missing, empty, expired, corrupt, unreadable and wrong-owner sessions, matching saved-session reuse, disabled behavior, page reconstruction and explicit sign-in before the first visit.
- Live Polimi sign-in and the installed beta were not exercised for this change.
