# Issue #243: real-time test inventory

Baseline `32472a9`; the changes are on `fix/real-time-test-determinism`. This inventory records which tests depend on real time and the choice made for each; it is not a claim that every timed test is deterministic. The call-site inventory at the end was taken on the baseline, so its line numbers are the baseline's. Run results (timings, full-suite runs under load, fault checks) are recorded in issue #243 and in the pull request, with the commit they were taken on.

## Changed tests and their fault checks

The 32 tests below comprise the original 21 and eleven additional corrections discovered under load. Each fault below was injected in a disposable copy, to see the named test fail for the intended reason; outcomes are in issue #243. Fixture mutations are identified explicitly and do not demonstrate a production-code defect. A timeout/hang must be distinguished from a build failure or an unrelated assertion.

| Test | Property and minimal fault to inject |
|---|---|
| `LiveAudioPipelineTests.anIsolationEndedWhileTheOriginalIsCopiedLeavesNoOriginal` | Remove the cleanup of the partial original after cancellation. |
| `MenuQuitTests.menuQuitCancelsTheSyncAndGoesOnOnceItStops` | Suppress cancellation of the running sync on menu quit. |
| `MenuQuitTests.menuQuitGivesUpWaitingAfterTheTimeout` | Remove the timeout branch of the wait. |
| `MenuQuitTests.cappedWaitReturnsOnWhicheverComesFirst` | Separately suppress task completion and timeout branches. |
| `RecmanWebSessionScriptTests.aScriptThatNeverAnswersEndsAtTheTimeout` | Suppress the script timeout. |
| `RecmanWebSessionScriptTests.closingEndsAScriptInFlight` | Suppress interruption of the script on close. |
| `RecmanWebSessionScriptTests.aNewOperationEndsThePreviousScript` | Suppress interruption of the previous call when a new one starts. |
| `RecmanWebSessionScriptTests.cancellingTheAwaitingTaskEndsTheScript` | Suppress interruption when the awaiting task is cancelled. |
| `RecmanWebSessionScriptTests.closingReleasesTheWebViewDespiteAStalledScript` | Suppress close's release of the WebView while the script is stalled. |
| `RecordingNowPlayingTests.slowOversizedOrBrokenAnswersFail` | Change the timer result from nil to empty data without changing its delay; retain the oversized and broken response checks. |
| `RecordingsAccountTests.aCoursePictureArrivingAfterAnAccountChangeIsDropped` | Allow the old account's picture result after changing accounts. |
| `RecordingsSyncFollowUpTests.theSchedulerCompletesWhileTheFollowUpIsStillBlocked` | Make scheduler completion await the blocked follow-up. |
| `RecordingsSyncFollowUpTests.cancellingAnAutomaticRunStopsTheFollowUp` | Suppress cancellation of the automatic follow-up when the schedule is dropped. |
| `RecordingsSyncFollowUpTests.droppingTheScheduleKeepsAManualRefreshTheAutomaticRunJoined` | Cancel the manual refresh when dropping the joined automatic schedule. |
| `RecordingsSyncFollowUpTests.droppingTheScheduleKeepsAnAutomaticRefreshAManualSyncJoined` | Cancel the automatic refresh after a manual sync has joined it. |
| `RecordingsSyncFollowUpTests.aManualSyncDoesNotMergeIntoAFollowUpTheDroppedScheduleCancelled` | Allow a manual sync to merge into the cancelled follow-up. |
| `RecordingsSyncFollowUpTests.menuQuitDoesNotWaitForTheFollowUp` | Make menu quit wait for the blocked follow-up. |
| `WebexSignInWebViewTests.closingOrANewOperationEndsAStreamWaitingOnWebex` | Separately suppress stream cancellation on close and on a newer operation. |
| `WebexStreamResolverTests.cancellingMidRequestEndsAtOnce` | Suppress cancellation propagation to the pending request. |
| `NetworkPathReaderTests.cancellationOfSilentProviderIsPromptAndCleansUp` | Suppress cancellation completion or resource cleanup. |
| `NetworkPathReaderTests.cancellationDuringInstallationReleasesLateResources` | Suppress cancellation completion, exercising cleanup after resources install late. |
| `VoiceIsolatorTests.steadyNoiseIsRemoved` | Fix noise seed at 7; retain the >20 dB assertion. Fixture mutation: measure input as output to model pass-through. |
| `LiveAudioSessionTests.avPlayerPlaysAcrossSegmentJoins` | Await terminal KVO readiness with a 45 s watchdog; retain seek, join and assertions. Fixture mutations: suppress readiness signal to trigger the watchdog assertion; separately force player rate to zero to exercise the join assertion. |
| `RecmanWebSessionScriptTests.anAnswerAfterTheCallEndedIsDropped` | Resolve the late script only after timeout; separately suppress late-signal recording and overwrite the settled outcome while retaining that signal. The latter requires the post-late outcome assertion being restored. |
| `RecordingsSyncFollowUpTests.aSecondManualSyncMergesWithTheRunningFollowUp` | Wait for the gated follow-up; ignore an eligible existing follow-up for manual sync and check reuse. |
| `UIFixtureTests.contentsGateKeepsARealSyncRunningUntilReleased` | Await the held-request event with a 45 s guard and join sync before disposal; disable holding contents and check the missing-event assertion. |
| `RecordingsSyncFollowUpTests.aManualSyncWithAnEmptyListLoadsItThenFollowsUpForced` | Await follow-up call event; pass false for force at the refresh seam and check forced refresh. |
| `RecordingsSyncFollowUpTests.signingOutDropsTheRunningFollowUp` | Await follow-up call event; suppress follow-up teardown specifically in course-list forgetting. |
| `UIFixtureTests.progressBurstTravelsTheThrottledSyncPath` | Extend only outer guard to two minutes; remove throttle rejection and check actor-entry bound. |
| `UIFixtureTests.largeCorporaReachRealControllers` | Extend only outer guard to two minutes; shorten recordings fixture by one and check corpus count. |
| `ActivityVirtualizationTests.revealedRowsStayLazyAndTheLastRowIsReachable` | Extend only outer guard to two minutes; replace inner lazy stack with eager stack and check constructed rows. |
| `RecordingPlayerMVPTests.theRememberedSpeedIsAppliedWithoutWriting` | Extend this readiness watchdog to 60 s; ignore the stored speed when starting playback and check the rate assertions. |

`cancellingAnAutomaticRunStopsTheFollowUp` was renamed from `cancellingAnAutomaticRunStopsTheFollowUpPromptly`. The Moodle URL protocol and other helpers also changed, affecting tests that use them; their call sites need review. Some tests retain a one-minute or two-minute time limit as a hang guard, and timeout-specific tests intentionally exercise real time. These bounds can still expire on an exceptionally loaded machine.

## Remaining timed logic and disposition

- **Event polling and deadlines:** `RecordingsControllerTests` and related `RecordingsWatchProgress`, `RecordingsMenuPlay`, `RecordingsMenuBar`, and `RecordingsSyncRefresh` helpers use `settle` loops and fixed `drainTasks` waits. `LiveAudioPipelineTests.eventually`, `WebexSignInWebViewTests.Harness.until` and `outcome`, `RecmanWebSessionTests.untilPending`, `RecordingsSyncFollowUpTests.waitForCalls` and `settle`, `SyncFinalizationTests.waitForChoice`, `SavedCourseListTests.waitUntil`, `LaunchAtLoginControllerTests.waitUntil`, and Core `RemoteDownloaderTests` / `RecmanSessionVaultTests` also use deadlines or polling. These are primarily event waits, but can fail under load; inspect each relevant caller and replace synchronization with signals where feasible. The changed Webex resolver test waits for a request event and observes transport cancellation, with a 45 s guard. Seven follow-up call sites use the common call event; the changed scheduler tests also coordinate through follow-up gates and deferral events; their bounded fallbacks remain hang guards.
- **Fixed sleeps before asserting an absence or ordering:** inspect `WebexSignInWebViewTests.aStallOnAPolimiPageKeepsThatPage`, `aNewerOperationKeepsItsPageWhenTheSignInEnds`, `aFailedLoadEndsAHiddenSignInButNotTheUsers`; `RecordingPlayerMVPTests.ticksReportProgressAndNeverCheckpoint`; `SavedCourseListTests.restoringASavedListRecordsNothing`; `CourseSelectionDuringRefreshTests.refreshWaitsForPendingCourseSelectionWrite`; `ActivityOpenTests.aFileNoAppCanOpenIsShownInFinderInstead`; `LaunchAtLoginControllerTests.aSecondTapWhileAChangeIsInFlightIsIgnored` and `theDefaultRegistrationAtLaunchLocksTheSwitch`; Core `RootOperationGateTests.releasesTheLeaseWhenAnOperationIsCancelled` and `SyncCoordinatorEndToEndTests.cancellationLeavesNoBaselineOrStagingArtifacts`. Retain negative observation windows where absence during a real interval is the behavior; where a sleep merely orders work, replace it with a signal or justify it per test.
- **Time is the behavior under test:** `SyncProgressStoreTests` and `UIFixtureTests.progressBurstTravelsTheThrottledSyncPath` cover cadence; `BoundedScriptCallTests` covers timeouts and late outcomes; `SyncDatabaseTests.writeWaitsForABusyDatabaseInsteadOfFailingImmediately` covers waiting on a lock. Prefer a controllable clock where practical while preserving the behavioral assertion; do not simply delete timing assertions.
- **UI, media and network integration:** `RecordingRowProgressTests`, `RecordingRowAccessibilityTests`, `UIContentReadinessTests`, `ActivityVirtualizationTests`, `RecordingsPresentationTests`, `SearchFieldFocusTests`, `RecordingPlayerControllerTests`, `PlayerZoomControllerTests`, `LiveAudioSessionTests`, Core `MetadataResponseTests` and `MetadataHTTPTests` use run-loop polling, real media/network callbacks or semaphore deadlines. Retain bounded real-signal polling where platform callbacks and progress are the observed behavior, with deadlines as hang guards; a deadline can still change a result under load. The AVPlayer join test retains its bounded progress poll and assertion.
- **Measurement tests:** `BenchmarkKitTests`, `BenchmarkUpstreamTests`, `MemoryMeasurementTests`, opt-in audio measurement suites and opt-in hash cancellation latency report intentionally measure time. Keep measurement semantics; isolate or document environmental sensitivity rather than presenting them as deterministic functional tests.
- **Non-wall-clock cases:** fixed epoch dates and an injected clock, such as `PerformancePolicyTests` and the injectable clock in `DailyTelemetryTests`, do not themselves wait for the wall clock. Other polling or blocking in those files still needs separate assessment.

The recovered audit also lists additional timed call sites, including inline polls in `RecordingsControllerTests`, `RecordingsMenuBarTests`, `RecmanScriptsTests` and `RecmanWebSessionTests`. This grouped disposition is a starting point, not proof of an exhaustive per-call-site review.

## Evidence

Historical issue evidence: the Webex sign-in interruption test took 31.7 s in a loaded full run on 2026-11-14 despite passing alone; the old assertion bounded it to 15 s. A block-copy experiment made the old live-audio copy window approximately 12 ms and caused its test to fail. These are historical observations, not measurements of this candidate.

While this work was under way, full-suite runs under load on intermediate states found further tests that failed only then, and each was corrected: `VoiceIsolatorTests.steadyNoiseIsRemoved` (random noise gave 16.7 dB against the 20 dB required; the input is now seeded), `LiveAudioSessionTests.avPlayerPlaysAcrossSegmentJoins` and `RecordingPlayerMVPTests.theRememberedSpeedIsAppliedWithoutWriting` (the player was not ready within the wait), the follow-up tests that polled for a call (now a fixture signal), the late script answer and the UI fixture tests, and five one-minute outer limits that ended at 62–67 s with no other issue (now two minutes; inner deadlines and assertions unchanged).

The fault checks in the table above were run in a disposable copy of the commit under test, one fault at a time; the outcome of each is in issue #243. By the user's decision the 20 isolated repetitions per test were not run and the full suite was run under load 7 times instead of 10; the issue records this.

## Baseline test and call-site inventory

This appendix scans all 123 Swift files under `Tests/` at `32472a9`. It found **378 test declarations with at least one matched timing expression or an explicitly changed test**, and **879 matched expressions** (the count includes any explicit changed test with no matched expression). These are lexical candidates, not runtime counts or proof of flakiness. Source line numbers identify the baseline. Parameterized test declarations count once; helper internals and non-test functions are not counted as test call sites. The scan matched 1,678 test declarations, but that is not a count of executed cases. No parse errors were reported.

The appendix reflects the original 21-test mapping at the baseline; the eleven later corrections are listed in the table above.

Disposition codes: **changed** = addressed by the candidate changes listed above, subject to final validation; **retain-hang-guard-review-order** = retain the deadline only as a guard and review whether ordering relies on polling or a fixed wait; **replace-or-justify-sleep** = replace synchronization sleeps with signals, or retain with a test-specific reason; **retain-time-behavior** = timing is named in the behavior and its assertion must be preserved; **retain-measurement** = retain measurement semantics and document environmental sensitivity; **hang-guard** = only clock/limit matched, review the actual use before declaring it harmless. Multiple codes apply independently. These are proposed dispositions for every listed call site; remaining cases are outside this diff and provisional under stress, not claims that they have been fixed or individually reviewed.

The heuristic excludes comments, string literals, fixed `Date(timeIntervalSince...)`, unqualified generic `wait` and `outcome` calls (which frequently denote event gates or result helpers rather than clock waits); this avoids treating all such uses as time-dependent but means their timed implementations require manual inspection. Calls to the named timing helpers are included with their call-site lines; the earlier grouped inventory identifies helper definitions. The lexical parser has limitations around unusual Swift strings/macros and should be supplemented by source review. This is not an exhaustive semantic proof.

<details>
<summary>Per-test candidates and dispositions (378 declarations)</summary>


**BeepbarAppTests/ActivityOpenTests.swift**

- `aFIFOAtTheTrackedPathIsMissingAndDoesNotBlock`: `.timeLimit(@210` — hang-guard.
- `aFileNoAppCanOpenIsShownInFinderInstead`: `Task.sleep(@306` — replace-or-justify-sleep.

**BeepbarAppTests/ActivityVirtualizationTests.swift**

- `revealedRowsStayLazyAndTheLastRowIsReachable`: `.timeLimit(@9`, `settle(@23`, `deadline@24`, `Date(@24`, `Task.sleep(@28`, `Date(@29`, `deadline@29`, `Task.sleep(@32` — replace-or-justify-sleep, retain-hang-guard-review-order.

**BeepbarAppTests/CourseSelectionDuringRefreshTests.swift**

- `renamingARestoredCourseFolderNeedsNoPrompt`: `Task.sleep(@26` — replace-or-justify-sleep.
- `refreshWaitsForPendingCourseSelectionWrite`: `Task.sleep(@109` — replace-or-justify-sleep.

**BeepbarAppTests/DailyTelemetryTests.swift**

- `transportCancelsAnUnfinishedResponseBody`: `Task.sleep(@572` — replace-or-justify-sleep.
- `transportCancellationFinishes`: `Task.sleep(@598` — replace-or-justify-sleep.
- `optOutStopsTheInFlightTransportAndSurvivesRelaunch`: `Task.sleep(@630`, `Task.sleep(@636` — replace-or-justify-sleep.

**BeepbarAppTests/DataSaverTests.swift**

- `schedulerKeepsDeadlineAndTracksRecovery`: `deadline@19`, `deadline@19`, `deadline@24`, `deadline@24` — hang-guard.
- `selectionInvalidatesPathButNotDeadline`: `deadline@64`, `deadline@64`, `deadline@68`, `deadline@68`, `deadline@72`, `deadline@72` — hang-guard.

**BeepbarAppTests/KeypointLevelerMeasurements.swift**

- `wholeLecture`: `Date(@615`, `Date(@616`, `Date(@616`, `Date(@643`, `Date(@645` — retain-measurement.

**BeepbarAppTests/LaunchAtLoginControllerTests.swift**

- `aSecondTapWhileAChangeIsInFlightIsIgnored`: `Task.sleep(@363` — replace-or-justify-sleep.
- `theDefaultRegistrationAtLaunchLocksTheSwitch`: `Task.sleep(@391` — replace-or-justify-sleep.

**BeepbarAppTests/LiveAudioMeasurements.swift**

- `measure`: `ContinuousClock.now@62`, `ContinuousClock.now@66`, `Task.sleep(@71`, `Task.sleep(@75` — replace-or-justify-sleep, retain-measurement.
- `aMinuteOfLevellingTakesMilliseconds`: `ContinuousClock(@98` — retain-measurement.

**BeepbarAppTests/LiveAudioPipelineTests.swift**

- `aReplacedPieceStaysUntilTheSegmentUsingItIsMade`: `eventually(@337`, `eventually(@339`, `eventually(@341`, `eventually(@348` — retain-hang-guard-review-order.
- `stopEndsEveryIsolationUnderway`: `eventually(@409`, `eventually(@411` — retain-hang-guard-review-order.
- `aSeekAwayEndsAnIsolationNoLongerNeeded`: `eventually(@435`, `eventually(@437` — retain-hang-guard-review-order.
- `anIsolationEndedBeforeItsPieceIsStoredLeavesNoFile`: `eventually(@463`, `eventually(@466` — retain-hang-guard-review-order.
- `anIsolationEndedWhileTheOriginalIsCopiedLeavesNoOriginal`: `eventually(@492`, `eventually(@495` — changed, retain-hang-guard-review-order.
- `theLatestRequestOutlivesAnEarlierOnesLateSeek`: `eventually(@533`, `eventually(@535` — retain-hang-guard-review-order.
- `anEndedRunDoesNotDeleteTheFilesOfTheNext`: `eventually(@553`, `eventually(@556`, `eventually(@560` — retain-hang-guard-review-order.
- `aPieceAlreadyCoveredIsDeleted`: `eventually(@579`, `eventually(@581`, `eventually(@584` — retain-hang-guard-review-order.
- `atMostKeptPiecesStayOnDisk`: `eventually(@610`, `eventually(@614` — retain-hang-guard-review-order.
- `aCoveredPieceTakesItsOriginalWithIt`: `eventually(@753`, `eventually(@755`, `eventually(@758`, `eventually(@763` — retain-hang-guard-review-order.
- `aSeekKeepsTheFragmentsWorkUnderwayReads`: `eventually(@796`, `eventually(@800` — retain-hang-guard-review-order.

**BeepbarAppTests/LiveAudioSessionTests.swift**

- `avPlayerPlaysAcrossSegmentJoins`: `deadline@159`, `Date(@159`, `Date(@160`, `deadline@160`, `Task.sleep(@160`, `Date(@164`, `Date(@165`, `Task.sleep(@165` — replace-or-justify-sleep.
- `goingBackToAPartHeardDoesNotIsolateItAgain`: `Task.sleep(@336` — replace-or-justify-sleep.

**BeepbarAppTests/MenuQuitTests.swift**

- `menuQuitCancelsTheSyncAndGoesOnOnceItStops`: `Task.sleep(@28`, `ContinuousClock.now@34`, `ContinuousClock.now@37` — changed, replace-or-justify-sleep.
- `menuQuitGivesUpWaitingAfterTheTimeout`: `Task.sleep(@60` — changed, replace-or-justify-sleep, retain-time-behavior.
- `cappedWaitReturnsOnWhicheverComesFirst`: `ContinuousClock.now@109`, `ContinuousClock.now@111`, `Task.sleep(@121` — changed, replace-or-justify-sleep.

**BeepbarAppTests/PlayerZoomControllerTests.swift**

- `theZoomStaysWithItsLecture`: `settle(@296` — retain-hang-guard-review-order.
- `theZoomCostsNothingAndStoresNothing`: `settle(@420`, `settle(@435` — retain-hang-guard-review-order.

**BeepbarAppTests/RecmanWebSessionTests.swift**

- `theSignInPageTakesEditingShortcutsWithoutAMenu`: `Task.sleep(@166` — replace-or-justify-sleep.
- `aScriptThatNeverAnswersEndsAtTheTimeout`: `.timeLimit(@322`, `ContinuousClock(@325`, `clock.now@326`, `clock.now@328` — changed, retain-time-behavior.
- `closingEndsAScriptInFlight`: `.timeLimit(@338`, `ContinuousClock(@342`, `clock.now@343`, `clock.now@347` — changed.
- `aNewOperationEndsThePreviousScript`: `.timeLimit(@353`, `ContinuousClock(@358`, `clock.now@359`, `clock.now@363` — changed.
- `cancellingTheAwaitingTaskEndsTheScript`: `.timeLimit(@370`, `ContinuousClock(@375`, `clock.now@376`, `clock.now@380` — changed.
- `anAnswerAfterTheCallEndedIsDropped`: `.timeLimit(@388`, `Task.sleep(@395` — replace-or-justify-sleep.
- `closingReleasesTheWebViewDespiteAStalledScript`: `.timeLimit(@406`, `Task.sleep(@416` — changed, replace-or-justify-sleep.

**BeepbarAppTests/RecordingNowPlayingTests.swift**

- `theMetadataNamesTheLectureAndTheCourse`: `Date(@157`, `Date(@162` — hang-guard.
- `slowOversizedOrBrokenAnswersFail`: `Task.sleep(@259`, `Date(@260`, `Date(@262` — changed, replace-or-justify-sleep.
- `playbackAndTitleNeverWaitForThePicture`: `.timeLimit(@292` — hang-guard.
- `aLatePictureOfAReplacedLectureIsDropped`: `.timeLimit(@321` — hang-guard.
- `theSameCoursesPictureIsFetchedOnce`: `.timeLimit(@350`, `settle(@363` — retain-hang-guard-review-order.
- `closingReleasesThePictureAndTheRecord`: `.timeLimit(@372`, `settle(@387` — retain-hang-guard-review-order.
- `aFailedPictureKeepsTheTitleAndCourse`: `.timeLimit(@404`, `settle(@412` — retain-hang-guard-review-order.
- `withoutMetadataTheTitleStillShows`: `.timeLimit(@423`, `settle(@435` — retain-hang-guard-review-order.
- `thePlayerTakesOverFromAVKitOnlyWhenItCan`: `.timeLimit(@445` — hang-guard.
- `theRecordFollowsPauseAndDuration`: `.timeLimit(@470` — retain-time-behavior.
- `remoteCommandsDriveThePlayer`: `.timeLimit(@485` — hang-guard.
- `anOldRemoteCommandCannotControlAReopenedWindow`: `.timeLimit(@509` — hang-guard.
- `bufferingPublishesNoMovingClock`: `.timeLimit(@618` — hang-guard.
- `noPictureIsFetchedWithoutARecord`: `.timeLimit(@636`, `settle(@643` — retain-hang-guard-review-order.
- `aFailedPictureIsRetriedByTheNextPlay`: `.timeLimit(@651` — hang-guard.
- `theRecordIsRepublishedOnlyWhenItChanges`: `.timeLimit(@668`, `settle(@676` — retain-hang-guard-review-order.
- `aRemotePlayDuringTheResumeWaitsForIt`: `.timeLimit(@694` — hang-guard.

**BeepbarAppTests/RecordingPlayerControllerTests.swift**

- `bringToFrontRestoresAMinimizedWindow`: `Task.sleep(@104`, `Task.sleep(@109` — replace-or-justify-sleep.
- `playAfterCloseStartsOver`: `settle(@256` — retain-hang-guard-review-order.
- `aStreamThatNeverPlaysReportsBeforeReadyAndCloses`: `.timeLimit(@326`, `settle(@338` — retain-hang-guard-review-order.
- `aPlayerViewThatCannotLoadReportsBeforeReady`: `.timeLimit(@353`, `settle(@361` — retain-hang-guard-review-order.
- `aPlayableFileBecomesReadyWithoutFailure`: `.timeLimit(@375`, `settle(@382` — retain-hang-guard-review-order.
- `aFailureDuringPlaybackKeepsTheWindowPaused`: `.timeLimit(@392`, `settle(@404` — retain-hang-guard-review-order.
- `resumingAfterAFailureReportsTheNextOneAgain`: `.timeLimit(@425` — hang-guard.
- `notificationsForOldItemsAreIgnored`: `.timeLimit(@452`, `settle(@463`, `settle(@467` — retain-hang-guard-review-order.

**BeepbarAppTests/RecordingPlayerMVPTests.swift**

- `theAudioMenuOffersThreeChoices`: `settle(@435`, `settle(@441` — retain-hang-guard-review-order.
- `theTitleBarSwitchTogglesEnhancedAudio`: `settle(@506` — retain-hang-guard-review-order.
- `startAtSeeksOnceThenPlays`: `settle(@727` — retain-hang-guard-review-order.
- `onePeriodicObserverExistsOnlyWhilePlaying`: `settle(@760`, `settle(@766`, `settle(@771`, `settle(@777`, `settle(@783` — retain-hang-guard-review-order.
- `settlingReplacesTheEarlyObserverWithALiveOne`: `settle(@802`, `settle(@813` — retain-hang-guard-review-order.
- `aStalledLectureKeepsItsObserver`: `settle(@833`, `settle(@837` — retain-hang-guard-review-order.
- `theObserverGoesOnReplacementAndFailure`: `settle(@873`, `settle(@883` — retain-hang-guard-review-order.
- `ticksReportProgressAndNeverCheckpoint`: `Task.sleep(@909` — replace-or-justify-sleep.
- `pausesReportOnce`: `settle(@991`, `settle(@996`, `settle(@1002`, `settle(@1005` — retain-hang-guard-review-order.
- `closingReportsBeforeTeardown`: `settle(@1031` — retain-hang-guard-review-order.
- `closingWhileLoadingReportsNothing`: `settle(@1044` — retain-hang-guard-review-order.
- `aFailureDuringTheResumeSeekReportsTheResumePosition`: `settle(@1095` — retain-hang-guard-review-order.
- `pausingDuringTheResumeIsHonouredWhenItLands`: `settle(@1141` — retain-hang-guard-review-order.
- `pausingDuringTheResumeStopsAPlayerTheStudentStarted`: `settle(@1178` — retain-hang-guard-review-order.
- `failuresReportOnceBeforeTheFailure`: `settle(@1277`, `settle(@1283`, `settle(@1292` — retain-hang-guard-review-order.
- `aViewWithoutAPlayerKeyFailsCleanly`: `.timeLimit(@1314` — hang-guard.

**BeepbarAppTests/RecordingRowAccessibilityTests.swift**

- `telemetrySettingsOptOutAfterClosingNotice`: `.timeLimit(@70`, `deadline@105`, `Date(@105`, `Task.sleep(@110`, `Date(@112`, `deadline@112`, `Task.sleep(@117` — replace-or-justify-sleep.
- `onlyNewRowsExposeTheDot`: `.timeLimit(@143` — hang-guard.
- `bookmarkButtonNamesTheLecture`: `.timeLimit(@160` — hang-guard.

**BeepbarAppTests/RecordingRowProgressTests.swift**

- `aTickReRendersOnlyThePlayingRow`: `.timeLimit(@337`, `settle(@353` — retain-hang-guard-review-order.
- `courseListMenuAndPrimaryActionReachTheList`: `.timeLimit(@365`, `settle(@382` — retain-hang-guard-review-order.
- `watchlistMenuAndPrimaryActionReachTheList`: `.timeLimit(@397`, `settle(@411` — retain-hang-guard-review-order.
- `aTickDoesNotScanTheListing`: `.timeLimit(@475` — hang-guard.
- `headerShowsTheCourseSummary`: `.timeLimit(@500` — hang-guard.
- `watchlistRowsShowTheirProgress`: `.timeLimit(@521` — hang-guard.
- `readerPassesCanEditProgress`: `.timeLimit(@546` — hang-guard.
- `theSidebarRowShowsItsNameAndLecturesLeftAndIgnoresTicks`: `.timeLimit(@565`, `settle(@591` — retain-hang-guard-review-order.

**BeepbarAppTests/RecordingsControllerTests.swift**

- `disabledCreationTouchesNothing`: `drainTasks(@629` — retain-hang-guard-review-order.
- `enabledByDefaultWithoutStartingWorkAndExplicitOptOutPersists`: `drainTasks(@641` — retain-hang-guard-review-order.
- `turningOnNeedsPolimiAndAKnownAccount`: `settle(@676` — retain-hang-guard-review-order.
- `theSwitchSurvivesARelaunch`: `drainTasks(@690` — retain-hang-guard-review-order.
- `anUnfinishedSignInKeepsTheSwitchOnAndSaysWhy`: `settle(@703`, `settle(@710`, `settle(@713` — retain-hang-guard-review-order.
- `turningOffForgetsEverything`: `settle(@724`, `settle(@735`, `drainTasks(@743` — retain-hang-guard-review-order.
- `firstVisitWithoutASessionShowsSignInWithoutOpeningABrowser`: `settle(@759`, `drainTasks(@766` — retain-hang-guard-review-order.
- `firstVisitReusesASavedSession`: `settle(@787`, `drainTasks(@796` — retain-hang-guard-review-order.
- `signInBeforeFirstVisitDoesNotRequireASavedSession`: `settle(@807` — retain-hang-guard-review-order.
- `anEmptyOrExpiredSessionShowsSignIn`: `settle(@824`, `drainTasks(@825` — retain-hang-guard-review-order.
- `aSlowSessionReadDefersThePageUntilItAnswers`: `settle(@847`, `drainTasks(@848`, `settle(@855`, `settle(@856`, `settle(@860`, `drainTasks(@861` — retain-hang-guard-review-order.
- `turningOffDuringASlowSaveLeavesNoSessionAndASignInSavesAgain`: `settle(@879`, `settle(@886` — retain-hang-guard-review-order.
- `aReadFinishingAfterTurnOffDoesNotAdoptItsOwner`: `settle(@901`, `drainTasks(@905`, `settle(@911`, `settle(@914`, `drainTasks(@915` — retain-hang-guard-review-order.
- `anAccountChangeDuringTheFirstReadDropsTheSession`: `settle(@933`, `settle(@937` — retain-hang-guard-review-order.
- `aSharedReadIsForgottenWhenTheFileChanges`: `settle(@957`, `settle(@966`, `drainTasks(@967`, `settle(@971` — retain-hang-guard-review-order.
- `anotherAccountsSessionIsDroppedUnused`: `settle(@986` — retain-hang-guard-review-order.
- `droppingAnotherAccountsSessionForgetsAddedLessonsProgress`: `settle(@1012` — retain-hang-guard-review-order.
- `anUnknownAccountUsesTheSavedSessionAndKeepsItsOwner`: `settle(@1033` — retain-hang-guard-review-order.
- `aDifferentAccountAppearingDropsTheLiveSession`: `settle(@1049` — retain-hang-guard-review-order.
- `anAccountAppearingDropsALiveSessionWithNoOwner`: `settle(@1079` — retain-hang-guard-review-order.
- `anAccountChangeWithNoSessionOwnerDropsListingsInMemory`: `settle(@1103`, `settle(@1111` — retain-hang-guard-review-order.
- `anUndecodableSessionIsDeletedButAnUnreadableOneIsKept`: `settle(@1134`, `settle(@1146` — retain-hang-guard-review-order.
- `noSessionIsSavedWithoutAnOwner`: `settle(@1159` — retain-hang-guard-review-order.
- `aVisitWithNothingNewWritesNothing`: `settle(@1170`, `drainTasks(@1171`, `settle(@1176`, `drainTasks(@1177`, `settle(@1183` — retain-hang-guard-review-order.
- `selectedFirstThenOthersAndRecentOnesAreSkipped`: `settle(@1196`, `drainTasks(@1200`, `settle(@1204`, `settle(@1208` — retain-hang-guard-review-order.
- `listingsOffThePageAreBoundedWhileThePageKeepsItsOwn`: `settle(@1221`, `settle(@1225`, `settle(@1232` — retain-hang-guard-review-order.
- `theSelectedCourseIsKeptEvenWhenNotAmongThePageKeys`: `settle(@1244`, `settle(@1247` — retain-hang-guard-review-order.
- `refreshingTheSamePageDoesNotRepublish`: `settle(@1260`, `drainTasks(@1261` — retain-hang-guard-review-order.
- `rememberedPlayersAreBounded`: `settle(@1282`, `settle(@1285`, `settle(@1287`, `settle(@1290`, `settle(@1292` — retain-hang-guard-review-order.
- `aLapsedSessionAsksForSignInThenReloads`: `settle(@1304`, `settle(@1311` — retain-hang-guard-review-order.
- `beingOfflineStopsTheBatch`: `settle(@1325` — retain-hang-guard-review-order.
- `otherFailuresStayWithTheirCourse`: `settle(@1340`, `settle(@1344` — retain-hang-guard-review-order.
- `aNewAttemptReplacesTheLastFailure`: `settle(@1358`, `settle(@1366`, `settle(@1368` — retain-hang-guard-review-order.
- `removedQueuedCourseDoesNotLoad`: `settle(@1387`, `settle(@1394`, `drainTasks(@1395`, `settle(@1400`, `drainTasks(@1401` — retain-hang-guard-review-order.
- `aPlayDroppedWithTheBatchSaysWhy`: `settle(@1416`, `settle(@1421` — retain-hang-guard-review-order.
- `aLateAnswerAfterTurningOffIsIgnored`: `settle(@1439`, `drainTasks(@1442` — retain-hang-guard-review-order.
- `closingTheWindowStopsWorkAndDropsTheBrowser`: `settle(@1460`, `drainTasks(@1465` — retain-hang-guard-review-order.
- `aRebuiltPageKeepsTheBrowserButLeavingDropsIt`: `settle(@1478`, `drainTasks(@1479`, `drainTasks(@1483`, `settle(@1486` — retain-hang-guard-review-order.
- `aSignInSurvivesTheWindowClosing`: `settle(@1500`, `settle(@1505` — retain-hang-guard-review-order.
- `playAndCopyOpenTheRightPlayerOnce`: `settle(@1520`, `settle(@1524`, `settle(@1528`, `settle(@1530` — retain-hang-guard-review-order.
- `aMissingPlayerSaysSo`: `settle(@1541` — retain-hang-guard-review-order.
- `aSlowOpeningCannotReplaceANewerCachedChoice`: `settle(@1558`, `settle(@1563`, `settle(@1570` — retain-hang-guard-review-order.
- `onlyTheLatestPlayOpensWhileALookupIsRunning`: `settle(@1591`, `settle(@1596` — retain-hang-guard-review-order.
- `onlyRecordingsPublishedLaterAreNew`: `settle(@1611`, `settle(@1617`, `settle(@1624`, `settle(@1631`, `settle(@1635` — retain-hang-guard-review-order.
- `leavingTheOpenCourseMarksItsNewRecordingsRead`: `settle(@1653`, `settle(@1657`, `drainTasks(@1658`, `settle(@1668`, `settle(@1674` — retain-hang-guard-review-order.
- `aCourseHiddenBehindTheSignInScreenIsNotLeft`: `drainTasks(@1700` — retain-hang-guard-review-order.
- `aLanguageSwitchIsNotLeavingTheCourse`: `drainTasks(@1715` — retain-hang-guard-review-order.
- `leavingAcrossAnAccountChangeTouchesNothingOfTheNextAccount`: `settle(@1734`, `drainTasks(@1742`, `settle(@1747`, `settle(@1749`, `settle(@1752`, `drainTasks(@1754`, `drainTasks(@1760` — retain-hang-guard-review-order.
- `switchingToTheSignInScreenLeavesTheCourse`: `settle(@1773` — retain-hang-guard-review-order.
- `openingAndLeavingACourseWithNothingNewWritesNothing`: `settle(@1785`, `drainTasks(@1789` — retain-hang-guard-review-order.
- `recordingsArrivingAfterLeavingStayNewUntilShown`: `settle(@1804`, `settle(@1810`, `drainTasks(@1812`, `drainTasks(@1819`, `settle(@1823` — retain-hang-guard-review-order.
- `historyBeyondFiveThousandSurvivesOtherCoursesAndRelaunch`: `settle(@1835`, `settle(@1844`, `settle(@1847`, `settle(@1851`, `settle(@1857`, `settle(@1862`, `settle(@1865` — retain-hang-guard-review-order.
- `migrationPreservesSurvivorsWithoutInventingLostHistory`: `settle(@1881`, `settle(@1888`, `settle(@1892`, `settle(@1896` — retain-hang-guard-review-order.
- `migrationWithoutOwnedSessionDoesNotInheritLegacyBaseline`: `settle(@1909`, `settle(@1911`, `settle(@1914` — retain-hang-guard-review-order.
- `failedMigrationPreservesLegacyForRetry`: `settle(@1933`, `settle(@1937` — retain-hang-guard-review-order.
- `historyRunsOffMainAndLateResultCannotReviveClosedPage`: `settle(@1949`, `settle(@1955`, `drainTasks(@1961` — retain-hang-guard-review-order.
- `transientHistoryFailureRetainsPreviousListAndRetries`: `settle(@1974`, `settle(@1978`, `settle(@1985`, `settle(@1993` — retain-hang-guard-review-order.
- `acknowledgementSuccessDoesNotHideFailedListRefresh`: `settle(@2007`, `settle(@2010`, `settle(@2017`, `settle(@2021`, `settle(@2025` — retain-hang-guard-review-order.
- `failedCleanupNeverReusesOldBaselineAfterReenableAndRelaunch`: `settle(@2036`, `drainTasks(@2040`, `settle(@2045`, `settle(@2047`, `settle(@2054`, `settle(@2058`, `settle(@2061` — retain-hang-guard-review-order.
- `heldAcknowledgementCannotRecreateHistoryAfterReset`: `settle(@2072`, `settle(@2075`, `settle(@2080`, `settle(@2083`, `settle(@2085`, `settle(@2088`, `drainTasks(@2090` — retain-hang-guard-review-order.
- `pendingAcknowledgementSurvivesPageCloseAndReopen`: `settle(@2102`, `settle(@2105`, `settle(@2110`, `settle(@2114`, `settle(@2116`, `settle(@2120` — retain-hang-guard-review-order.
- `repeatedAcknowledgementsAreCoalescedWhileDiskIsSlow`: `settle(@2131`, `settle(@2134`, `settle(@2139`, `drainTasks(@2140`, `settle(@2143` — retain-hang-guard-review-order.
- `delayedReadCannotOverwriteNewerAcknowledgement`: `settle(@2154`, `settle(@2157`, `settle(@2162`, `settle(@2164`, `settle(@2166` — retain-hang-guard-review-order.
- `forgettingStudyDataOnlyErasesTheCurrentAccount`: `settle(@2208` — retain-hang-guard-review-order.
- `forgettingStudyDataDoesNotGrantAccess`: `settle(@2238` — retain-hang-guard-review-order.
- `expiredSessionIsDeletedAtStartupWithoutOpeningABrowser`: `Date(@2246`, `settle(@2248` — retain-hang-guard-review-order.
- `studyErasureFailureIsVisibleAcrossRelaunchAndRetryable`: `settle(@2260`, `settle(@2264`, `drainTasks(@2267`, `settle(@2271` — retain-hang-guard-review-order.
- `aManualLessonPlaysAndFallsBackToItsOwnLink`: `settle(@2394`, `settle(@2400`, `settle(@2403` — retain-hang-guard-review-order.
- `aPlayNamesAnUntitledLessonAndGivesItsLength`: `settle(@2418`, `settle(@2432` — retain-hang-guard-review-order.
- `aRecoveryRestartsTheStoredKind`: `settle(@2624` — retain-hang-guard-review-order.
- `aFailingFilterFallsBackToTheStreamWithoutALoop`: `drainTasks(@2685` — retain-hang-guard-review-order.
- `aModeThatStartsThenFailsStaysSavedAndIsTriedOnTheNextLecture`: `drainTasks(@2731`, `drainTasks(@2738` — retain-hang-guard-review-order.
- `aFilterFailingBeforeReadyPlaysTheStreamFromTheSameStart`: `settle(@2751` — retain-hang-guard-review-order.
- `aPassingOrExpiredStreamIsRecoveredAndFilteredAgain`: `settle(@2781` — retain-hang-guard-review-order.
- `aPassingFailureBeforeReadyKeepsEnhancedAudio`: `settle(@2806`, `drainTasks(@2813` — retain-hang-guard-review-order.
- `aRefusalBeforeReadyTakesTheUsualPath`: `settle(@2835`, `settle(@2841` — retain-hang-guard-review-order.
- `anUnexplainedFailureMidLectureKeepsEnhancedAudio`: `drainTasks(@2866` — retain-hang-guard-review-order.
- `closingBeforeReadyStopsTheFilter`: `settle(@2890` — retain-hang-guard-review-order.
- `failuresGoWithTheAccountAndNoEnhancerIsMadeToForget`: `settle(@2911`, `settle(@2921`, `settle(@2923` — retain-hang-guard-review-order.
- `withoutFFmpegTheMenuSaysHowToGetIt`: `drainTasks(@2955` — retain-hang-guard-review-order.
- `aStaleAudioChoiceIsIgnored`: `drainTasks(@2997` — retain-hang-guard-review-order.
- `aStaleFilterReportIsIgnored`: `settle(@3018` — retain-hang-guard-review-order.
- `playbackCopyAndBaselineNeverChangeBookmarks`: `settle(@3032`, `settle(@3036`, `settle(@3038` — retain-hang-guard-review-order.
- `disablingAndFailedSignInPreserveStudyChoices`: `settle(@3077` — retain-hang-guard-review-order.
- `refreshUpdatesBookmarksAndMarksMissingWithoutDeleting`: `settle(@3110`, `settle(@3114`, `settle(@3119` — retain-hang-guard-review-order.
- `playStreamsInTheNativePlayerAndCreatesItOnlyThen`: `settle(@3167`, `settle(@3172`, `settle(@3176`, `settle(@3184` — retain-hang-guard-review-order.
- `aStreamThatCantBeUsedFallsBackOrReports`: `settle(@3209`, `settle(@3212`, `settle(@3217`, `settle(@3220` — retain-hang-guard-review-order.
- `openInBrowserOpensTheBrowserWithoutTheNativePlayer`: `settle(@3286`, `settle(@3292` — retain-hang-guard-review-order.
- `onlyTheLatestPlayStartsTheNativePlayer`: `settle(@3308`, `settle(@3311`, `drainTasks(@3312` — retain-hang-guard-review-order.
- `aNewerPlayCancelsTheStaleLookup`: `settle(@3332`, `settle(@3334` — retain-hang-guard-review-order.
- `aSecondPlayOfTheSameLectureJoinsTheRunningLookup`: `settle(@3355`, `drainTasks(@3357`, `settle(@3360`, `drainTasks(@3361` — retain-hang-guard-review-order.
- `aPlayAgainRightAfterThePlayerStartedIsNotSwallowed`: `settle(@3383` — retain-hang-guard-review-order.
- `aLateStreamAfterTurningOffStartsNothing`: `settle(@3398`, `drainTasks(@3401` — retain-hang-guard-review-order.
- `theStoppedPlaceIsWrittenOnReportsAndResumed`: `settle(@3419`, `settle(@3430`, `settle(@3433` — retain-hang-guard-review-order.
- `aFinishedLectureStartsOverAndLeavesNothingStored`: `settle(@3446`, `settle(@3452` — retain-hang-guard-review-order.
- `positionsBelongToTheirAccount`: `settle(@3470` — retain-hang-guard-review-order.
- `identityChangesCloseThePlayerAndForgetPlaces`: `settle(@3488` — retain-hang-guard-review-order.
- `disablingKeepsTheLastPlaybackPosition`: `settle(@3517`, `settle(@3526`, `settle(@3528` — retain-hang-guard-review-order.
- `accountChangeAfterDisablingChecksTheStoredPositionOwner`: `settle(@3539` — retain-hang-guard-review-order.
- `closingTheWindowKeepsTheLecturePlaying`: `settle(@3556`, `drainTasks(@3558` — retain-hang-guard-review-order.
- `aPlayHandsThePlayerTheLectureCourseAndPicture`: `settle(@3582` — retain-hang-guard-review-order.
- `aRecoveryKeepsTheCourseAndPicture`: `settle(@3597`, `settle(@3600` — retain-hang-guard-review-order.
- `twoCoursesSharingAKeyUseTheSelectedOne`: `settle(@3617` — retain-hang-guard-review-order.
- `aReplayAfterCloseReadsTheCourseAgain`: `settle(@3640`, `settle(@3646` — retain-hang-guard-review-order.
- `aReplayAfterAWindowClosedBeforeReadyReadsTheCourseAgain`: `settle(@3668`, `settle(@3675` — retain-hang-guard-review-order.
- `aMenuCourseNeverPlayedDoesNotSurviveAnAccountChange`: `settle(@3699`, `drainTasks(@3700`, `settle(@3706`, `settle(@3710` — retain-hang-guard-review-order.
- `anAccountChangeDropsThePlaybackMetadata`: `settle(@3724`, `settle(@3730`, `settle(@3732` — retain-hang-guard-review-order.
- `aStreamThatDiesIsResolvedOnceMoreThenTheBrowserOpens`: `settle(@3764`, `settle(@3767`, `settle(@3773` — retain-hang-guard-review-order.
- `recoveryEndsInTheBrowser`: `settle(@3789`, `settle(@3791` — retain-hang-guard-review-order.
- `aRecoveryThatEndsWithNothingTellsThePlayerWindow`: `settle(@3818`, `settle(@3821`, `settle(@3824` — retain-hang-guard-review-order.
- `aFailureWhileSignedOutTellsThePlayerWindow`: `settle(@3844`, `settle(@3847` — retain-hang-guard-review-order.
- `aRecoveryWithTheWindowClosedLeavesNoBrowserBehind`: `settle(@3860`, `drainTasks(@3862`, `settle(@3866`, `settle(@3867` — retain-hang-guard-review-order.
- `theConfirmedEmailSurvivesLaterSaves`: `settle(@3893` — retain-hang-guard-review-order.
- `aSavedEmailIsReadAfterARelaunchAndUsedByPlay`: `settle(@3930` — retain-hang-guard-review-order.
- `theProfileAddressIsUsedWithoutConfirmation`: `settle(@3961`, `settle(@3964` — retain-hang-guard-review-order.
- `theFirstPlayUsesTheProfileAddressWithoutSettings`: `settle(@3984`, `settle(@3987`, `settle(@3989` — retain-hang-guard-review-order.
- `aPlayDuringTheSettingsLookupWaitsForIt`: `settle(@4039`, `drainTasks(@4041`, `settle(@4045` — retain-hang-guard-review-order.
- `anAddressConfirmedBeforeSigningInIsWrittenBySignIn`: `settle(@4074` — retain-hang-guard-review-order.
- `aLateProfileAnswerAfterAnAccountChangeIsDropped`: `settle(@4113`, `drainTasks(@4118` — retain-hang-guard-review-order.
- `closingThePlayerRejectsALateRecoveryFallback`: `settle(@4159`, `settle(@4165`, `settle(@4169` — retain-hang-guard-review-order.
- `aSecondFailureDuringARecoveryQueuesNoSecondRecovery`: `settle(@4194`, `settle(@4199`, `settle(@4203`, `drainTasks(@4204` — retain-hang-guard-review-order.
- `aFailureOfANewerItemIsRecoveredWhileAStaleRecoveryIsPending`: `settle(@4236`, `settle(@4242`, `settle(@4257`, `settle(@4261`, `settle(@4264`, `drainTasks(@4265` — retain-hang-guard-review-order.
- `aStaleRecoveryNeverReplacesTheNewerItemOfTheSameLecture`: `settle(@4284`, `settle(@4289`, `settle(@4295`, `settle(@4297`, `drainTasks(@4298` — retain-hang-guard-review-order.
- `aNewPlayRejectsALateRecoveryLink`: `settle(@4313`, `settle(@4319`, `settle(@4323`, `settle(@4324` — retain-hang-guard-review-order.
- `aFailedSessionDeletionCannotRestoreTheDiscardedSession`: `settle(@4342`, `settle(@4345`, `settle(@4347`, `settle(@4352`, `drainTasks(@4361` — retain-hang-guard-review-order.
- `retryingFailedSessionDeletionRemovesTheResidue`: `settle(@4373`, `settle(@4376` — retain-hang-guard-review-order.
- `aFailedSessionDeletionIsRetriedLater`: `drainTasks(@4399`, `settle(@4413`, `drainTasks(@4415` — retain-hang-guard-review-order.
- `aSaveFinishingDuringANewerSignInStillClearsTheDiscardFlag`: `settle(@4437`, `drainTasks(@4439`, `settle(@4445`, `settle(@4452`, `drainTasks(@4455`, `drainTasks(@4463` — retain-hang-guard-review-order.
- `aRecoveryOutlivesTheWindowClosing`: `settle(@4484`, `settle(@4490`, `settle(@4495`, `settle(@4500`, `settle(@4502` — retain-hang-guard-review-order.
- `copyingALinkDoesNotCancelARecovery`: `settle(@4515`, `settle(@4521`, `settle(@4525`, `settle(@4526` — retain-hang-guard-review-order.
- `anAddressLearnedBeforeAnyPolimiSessionStaysWithItsAccount`: `settle(@4542`, `settle(@4559`, `settle(@4564` — retain-hang-guard-review-order.
- `closingTheWindowKeepsAPlayQueuedBehindARecovery`: `settle(@4581`, `settle(@4586`, `settle(@4591`, `settle(@4592` — retain-hang-guard-review-order.
- `closingTheWindowDropsACopyQueuedBehindARecovery`: `settle(@4608`, `settle(@4613`, `settle(@4619`, `settle(@4620` — retain-hang-guard-review-order.
- `aStreamFailureAfterTheLinkOpensThatLink`: `settle(@4638`, `settle(@4641` — retain-hang-guard-review-order.
- `aWrappedReportedFailureIsStillReported`: `settle(@4665`, `settle(@4668`, `settle(@4671`, `settle(@4673`, `drainTasks(@4675` — retain-hang-guard-review-order.
- `anAddressIsRefusedWhileNoAccountIsKnown`: `settle(@4693`, `settle(@4703`, `settle(@4706` — retain-hang-guard-review-order.
- `thePolicyHandOverReachesTheOpenPlayer`: `settle(@4721` — retain-hang-guard-review-order.
- `aSessionOfAnotherAccountFoundOnReadClosesThePlayer`: `settle(@4737`, `drainTasks(@4742`, `settle(@4745`, `settle(@4746` — retain-hang-guard-review-order.
- `aFailureMidLectureStoresThePlaceAtOnce`: `settle(@4762`, `settle(@4768` — retain-hang-guard-review-order.
- `aFailureWhileSignedOutDoesNotSpendTheRetry`: `settle(@4781`, `settle(@4784`, `drainTasks(@4788`, `settle(@4794`, `settle(@4796` — retain-hang-guard-review-order.
- `aFailureToStartWhileSignedOutSaysSo`: `settle(@4809`, `settle(@4812`, `settle(@4814` — retain-hang-guard-review-order.
- `aRecoveryWithoutAnEmailOpensNoWebexPage`: `settle(@4841`, `settle(@4843` — retain-hang-guard-review-order.
- `anUnreadableSessionKeepsItsEmailThroughTheNextSave`: `settle(@4861`, `settle(@4866`, `settle(@4869` — retain-hang-guard-review-order.
- `signingInToAnotherWeBeepAccountDropsTheSession`: `Task.sleep(@4971` — replace-or-justify-sleep.
- `disconnectingClosesThePlayerAndForgetsPlaces`: `Task.sleep(@5001` — replace-or-justify-sleep.
- `aProfileAddressArrivingAfterAnAccountChangeIsDropped`: `Task.sleep(@5063` — replace-or-justify-sleep.
- `aCoursePictureArrivingAfterAnAccountChangeIsDropped`: `Task.sleep(@5086` — changed, replace-or-justify-sleep.

**BeepbarAppTests/RecordingsMenuBarTests.swift**

- `aLoadedListingReachesTheMenuAndTurningOffClearsIt`: `Task.sleep(@281` — replace-or-justify-sleep.
- `renamingAFolderRedrawsTheLine`: `Task.sleep(@552` — replace-or-justify-sleep.
- `aLineIsClickableOnlyWithAPlayableNext`: `Date(@627` — hang-guard.
- `aClickHopsToTheMainActorAndPlaysTheNextLecture`: `settle(@725` — retain-hang-guard-review-order.
- `aForeignPayloadIsIgnored`: `drainTasks(@742` — retain-hang-guard-review-order.
- `aStaleClickDoesNothing`: `drainTasks(@805` — retain-hang-guard-review-order.
- `anAccountChangeBetweenDrawingAndClickingIsIgnored`: `drainTasks(@837` — retain-hang-guard-review-order.
- `aPlayThatNeedsTheWindowOpensTheCoursePage`: `settle(@856`, `settle(@863` — retain-hang-guard-review-order.
- `aSharedArchiveKeyOpensTheFirstSyncedCourse`: `settle(@891` — retain-hang-guard-review-order.

**BeepbarAppTests/RecordingsMenuPlayTests.swift**

- `aTickWritesNothingAndKeepsTheNextLecture`: `settle(@180`, `drainTasks(@186` — retain-hang-guard-review-order.
- `aCheckpointOrACompletionMovesTheNextLecture`: `settle(@206` — retain-hang-guard-review-order.
- `completingTheSavedNextWithoutAListingClearsIt`: `settle(@241`, `settle(@242` — retain-hang-guard-review-order.
- `aMenuPlayWithNoPageResumesListsAndClosesTheBrowser`: `settle(@275`, `settle(@277`, `settle(@278` — retain-hang-guard-review-order.
- `aMenuPlayUsesTheClickedLinesCourseForNowPlaying`: `settle(@299` — retain-hang-guard-review-order.
- `aMenuPlayKeepsThePagesQueuedListings`: `settle(@319`, `settle(@324` — retain-hang-guard-review-order.
- `theLectureAlreadyOpenIsBroughtForwardNotReplayed`: `settle(@341`, `drainTasks(@343` — retain-hang-guard-review-order.
- `aMenuPlayNeedsTheWindowWhenOffOrSignedOut`: `settle(@364`, `settle(@370`, `drainTasks(@372` — retain-hang-guard-review-order.
- `anInvalidNextIsNeverOpenedAndAsksForThePage`: `drainTasks(@389` — retain-hang-guard-review-order.
- `aClickForAnotherAccountIsIgnored`: `drainTasks(@405` — retain-hang-guard-review-order.
- `aLapsedSessionAsksForTheCoursePage`: `settle(@425` — retain-hang-guard-review-order.
- `aLectureThatCantBeOpenedAsksForTheCoursePage`: `settle(@439` — retain-hang-guard-review-order.
- `aFailedMenuPlayWithAPageOnScreenDoesNotAskAgain`: `settle(@454`, `drainTasks(@455` — retain-hang-guard-review-order.
- `aMenuPlayDroppedBecausePolimiIsUnreachableAsksForThePage`: `settle(@475`, `settle(@479` — retain-hang-guard-review-order.
- `aMenuPlayDroppedBehindALapsedListingAsksForThePage`: `settle(@501`, `settle(@505` — retain-hang-guard-review-order.
- `aWindowPlaysFailureNeverAsksForThePage`: `settle(@524`, `drainTasks(@525`, `settle(@532`, `settle(@537`, `drainTasks(@538` — retain-hang-guard-review-order.
- `closingTheWindowMidPlayDoesNotCancelIt`: `settle(@561`, `settle(@564`, `settle(@565` — retain-hang-guard-review-order.
- `closingTheWindowPreservesCurrentWorkAfterAnInvalidatedWorkerReturns`: `settle(@581`, `drainTasks(@582`, `settle(@589`, `settle(@596`, `drainTasks(@600`, `settle(@603`, `settle(@605` — retain-hang-guard-review-order.

**BeepbarAppTests/RecordingsPresentationTests.swift**

- `watchlistHeaderStaysAtTopWhenLastLessonIsRemoved`: `settle(@200`, `deadline@201`, `Date(@201`, `Date(@202`, `deadline@202`, `Task.sleep(@204` — replace-or-justify-sleep, retain-hang-guard-review-order.

**BeepbarAppTests/RecordingsSessionStoreTests.swift**

- `sessionLifetimeIsNotExtendedByReplacement`: `Date(@72` — hang-guard.

**BeepbarAppTests/RecordingsSyncFollowUpTests.swift**

- `switchOffOrAnotherUniversityStartsNothing`: `settle(@26` — retain-hang-guard-review-order.
- `theSchedulerCompletesWhileTheFollowUpIsStillBlocked`: `deadline@90`, `ContinuousClock.now@90`, `ContinuousClock.now@91`, `deadline@91`, `Task.sleep(@91` — changed, replace-or-justify-sleep.
- `aManualSyncWithAnEmptyListLoadsItThenFollowsUpForced`: `waitForCalls(@122` — retain-hang-guard-review-order.
- `aSecondManualSyncMergesWithTheRunningFollowUp`: `waitForCalls(@138`, `settle(@143` — retain-hang-guard-review-order.
- `cancellingTheMaterialsRunStartsNoFollowUp`: `settle(@289` — retain-hang-guard-review-order.
- `cancellingAnAutomaticRunStopsTheFollowUpPromptly`: `waitForCalls(@347`, `ContinuousClock.now@349`, `ContinuousClock.now@355` — changed, retain-hang-guard-review-order.
- `droppingTheScheduleKeepsAManualRefreshTheAutomaticRunJoined`: `waitForCalls(@374`, `settle(@375`, `waitUntilHeld(@379`, `ContinuousClock.now@383`, `ContinuousClock.now@386`, `Task.sleep(@387` — changed, replace-or-justify-sleep, retain-hang-guard-review-order.
- `droppingTheScheduleKeepsAnAutomaticRefreshAManualSyncJoined`: `waitForCalls(@404`, `settle(@407`, `ContinuousClock.now@410`, `ContinuousClock.now@413`, `Task.sleep(@414` — changed, replace-or-justify-sleep, retain-hang-guard-review-order.
- `aManualSyncDoesNotMergeIntoAFollowUpTheDroppedScheduleCancelled`: `waitForCalls(@433`, `waitForCalls(@442` — changed, retain-hang-guard-review-order.
- `aSchedulerAskingToDeferSkipsTheFollowUp`: `settle(@474` — retain-hang-guard-review-order.
- `menuQuitDoesNotWaitForTheFollowUp`: `waitForCalls(@493`, `ContinuousClock.now@497`, `ContinuousClock.now@499` — changed, retain-hang-guard-review-order.
- `aRunEndingWhileQuittingStartsNoFollowUp`: `settle(@513` — retain-hang-guard-review-order.
- `signingOutDropsTheRunningFollowUp`: `waitForCalls(@527` — retain-hang-guard-review-order.

**BeepbarAppTests/RecordingsSyncRefreshTests.swift**

- `zeroCostSkips`: `drainTasks(@141` — retain-hang-guard-review-order.
- `identityChangesPublishNothing`: `settle(@259`, `drainTasks(@270` — retain-hang-guard-review-order.
- `closingThePageDoesNotCancelTheBackgroundRefresh`: `settle(@289` — retain-hang-guard-review-order.
- `closingThePageKeepsQueuedBackgroundCoursesAndDropsThePagesOwn`: `settle(@311`, `drainTasks(@313` — retain-hang-guard-review-order.
- `aBackgroundRequestKeepsThePagesQueueAndOrder`: `settle(@335`, `drainTasks(@337` — retain-hang-guard-review-order.
- `theBackgroundRequestComesAfterThePagesCourses`: `settle(@357`, `drainTasks(@359` — retain-hang-guard-review-order.
- `aMenuPlayAndABackgroundRefreshKeepEachOther`: `settle(@378`, `settle(@382` — retain-hang-guard-review-order.
- `cancellationIsPromptAndReleasesEverything`: `settle(@402`, `drainTasks(@412` — retain-hang-guard-review-order.
- `cancellationWithAPageKeepsThePagesWork`: `settle(@432`, `drainTasks(@434`, `settle(@438`, `drainTasks(@439` — retain-hang-guard-review-order.
- `cancellationKeepsACourseThePageRequestedAfterTheBackgroundRefresh`: `settle(@454`, `settle(@456`, `settle(@461` — retain-hang-guard-review-order.
- `newCountIsUnseenAndNotCompleted`: `drainTasks(@555`, `drainTasks(@559`, `drainTasks(@566` — retain-hang-guard-review-order.

**BeepbarAppTests/RecordingsWatchProgressTests.swift**

- `bulkPendingValuesStayCommittedAcrossPageClose`: `settle(@229` — retain-hang-guard-review-order.
- `bulkFailureMidwaySavesNothing`: `settle(@300`, `drainTasks(@307`, `settle(@322` — retain-hang-guard-review-order.
- `bulkUntickPreservesPositionAndDoesNotRestoreNewDots`: `settle(@389`, `settle(@392`, `settle(@398` — retain-hang-guard-review-order.
- `bulkCannotCrossIdentityBoundary`: `settle(@452` — retain-hang-guard-review-order.
- `bulkStoppedByAnUnresetAccountChangeReleasesTheCourse`: `settle(@476`, `settle(@481`, `settle(@486` — retain-hang-guard-review-order.
- `ticksStayInMemory`: `drainTasks(@517` — retain-hang-guard-review-order.
- `aRecoveryOfTheSameLectureIsNotAClose`: `settle(@603`, `settle(@606` — retain-hang-guard-review-order.
- `tickingSavesThenShowsAndClearsTheNewDot`: `settle(@643`, `settle(@647`, `settle(@655` — retain-hang-guard-review-order.
- `writesCommitInOrder`: `settle(@745`, `drainTasks(@749` — retain-hang-guard-review-order.
- `aStaleSnapshotNeverOverwritesACommit`: `settle(@794`, `settle(@797`, `settle(@799` — retain-hang-guard-review-order.
- `aRelaunchShowsTheStoredPercentage`: `settle(@818` — retain-hang-guard-review-order.
- `theSummaryIsWrittenOnlyWhenItChanges`: `settle(@842`, `settle(@846`, `settle(@851`, `drainTasks(@852` — retain-hang-guard-review-order.
- `anIdentityChangeMidPlaybackLeavesNothing`: `settle(@909`, `drainTasks(@927` — retain-hang-guard-review-order.
- `aLateCommitAfterAResetIsNeverShown`: `settle(@944`, `settle(@947`, `settle(@949`, `drainTasks(@952` — retain-hang-guard-review-order.
- `completingByPlaybackClearsTheNewDot`: `settle(@1051`, `settle(@1054`, `settle(@1061` — retain-hang-guard-review-order.
- `failedCheckpointsAreForgottenWithTheHistory`: `settle(@1079` — retain-hang-guard-review-order.
- `aQueuedWriteNeverReachesTheNextHistory`: `settle(@1100`, `settle(@1105`, `drainTasks(@1107`, `drainTasks(@1108` — retain-hang-guard-review-order.
- `theFirstChangeAfterARelaunchKeepsOtherCourses`: `settle(@1121`, `settle(@1126`, `settle(@1133` — retain-hang-guard-review-order.
- `aCommitForAnAccountNoLongerConnectedIsNotShown`: `settle(@1242` — retain-hang-guard-review-order.

**BeepbarAppTests/SavedCourseListTests.swift**

- `aLaunchDeletesAnExpiredListWithoutTheWindow`: `Date(@593`, `Date(@600` — hang-guard.
- `aBlockedLaunchStillDeletesAnExpiredList`: `Date(@615` — hang-guard.
- `anAutomaticSyncDeletesAnExpiredList`: `Date(@666` — hang-guard.
- `aSyncOverACurrentListDeletesAnExpiredList`: `Date(@682` — hang-guard.
- `restoringASavedListRecordsNothing`: `Task.sleep(@811` — replace-or-justify-sleep.

**BeepbarAppTests/SyncCompletionRedrawTests.swift**

- `endingOperationAfterFinalStateInvalidatesWindow`: `Date(@14` — hang-guard.

**BeepbarAppTests/SyncCopyTests.swift**

- `partialDetailSeparatesInaccessibleCoursesFromFailedFiles`: `Date(@22` — hang-guard.
- `filesMovedToFollowMoodleAreCountedButKeptOnesAreNot`: `Date(@33` — hang-guard.

**BeepbarAppTests/SyncFinalizationTests.swift**

- `benchmarkSummaryPersist`: `ContinuousClock.now@400`, `ContinuousClock.now@402`, `ContinuousClock.now@406`, `ContinuousClock.now@408`, `ContinuousClock.now@412`, `ContinuousClock.now@415`, `ContinuousClock.now@417`, `ContinuousClock.now@420`, `ContinuousClock.now@422` — hang-guard.
- `benchmarkSummaryRestore`: `ContinuousClock.now@477`, `ContinuousClock.now@479`, `ContinuousClock.now@480`, `ContinuousClock.now@482`, `ContinuousClock.now@483`, `ContinuousClock.now@485` — hang-guard.
- `remoteRefusalIsVisibleAndSuccessfulChoiceClearsIt`: `waitForChoice(@971`, `waitForChoice(@979` — retain-hang-guard-review-order.
- `ordinaryConflictRefusalAndFailureAreVisible`: `waitForChoice(@998`, `waitForChoice(@1005` — retain-hang-guard-review-order.
- `aChoiceBlockedByAnUnreadableMoveNamesThePath`: `waitForChoice(@1031` — retain-hang-guard-review-order.
- `lateDatabaseFailureDoesNotPromiseLocalPreservation`: `waitForChoice(@1099` — retain-hang-guard-review-order.
- `changedRootOrDisconnectClearsChoiceFeedback`: `waitForChoice(@1115` — retain-hang-guard-review-order.

**BeepbarAppTests/SyncProgressStoreTests.swift**

- `burstOfEventsEntersTheMainActorOncePerInterval`: `ContinuousClock.now@33` — hang-guard.
- `automaticRunUsesTheOneSecondCadence`: `ContinuousClock.now@96`, `Task.sleep(@98` — replace-or-justify-sleep, retain-time-behavior.
- `manualRunUsesTheTwoHundredMillisecondCadence`: `Task.sleep(@125` — replace-or-justify-sleep, retain-time-behavior.

**BeepbarAppTests/UIContentReadinessTests.swift**

- `movingTheMarkerKeepsTheRowState`: `settle(@62`, `settle(@67` — retain-hang-guard-review-order.

**BeepbarAppTests/UIFixtureTests.swift**

- `contentsGateKeepsARealSyncRunningUntilReleased`: `.timeLimit(@88` — hang-guard.
- `largeCorporaReachRealControllers`: `.timeLimit(@104` — hang-guard.
- `progressBurstTravelsTheThrottledSyncPath`: `.timeLimit(@127`, `ContinuousClock.now@130` — retain-time-behavior.

**BeepbarAppTests/WebexSignInWebViewTests.swift**

- `thePlaybackPageIsCancelledAndTheTicketEndsTheSignIn`: `.timeLimit(@113`, `untilBlank(@128` — retain-hang-guard-review-order.
- `aTicketMidChainEndsTheSignIn`: `.timeLimit(@143` — hang-guard.
- `aPasswordPageShowsTheWindowAndClosingItCancels`: `.timeLimit(@155` — hang-guard.
- `aPasswordPageWithoutTheUserNeedsSignIn`: `.timeLimit(@166` — hang-guard.
- `aStalledChainHandsOverToTheUser`: `.timeLimit(@177` — hang-guard.
- `aChainThatNeverEndsHitsTheDeadline`: `.timeLimit(@188`, `deadline@191` — hang-guard.
- `thePlaybackPageWithoutATicketEndsInTheBrowser`: `.timeLimit(@197` — hang-guard.
- `aHostOffTheChainEndsTheSignIn`: `.timeLimit(@217`, `untilBlank(@224` — retain-hang-guard-review-order.
- `closingOrCancellingEndsTheSignIn`: `.timeLimit(@238`, `untilBlank(@253` — retain-hang-guard-review-order.
- `aStallRestartsWithoutTheHintAndThePlaybackPageEndsIt`: `.timeLimit(@262`, `untilBlank(@276` — retain-hang-guard-review-order.
- `aStallOnAPolimiPageKeepsThatPage`: `.timeLimit(@281`, `Task.sleep(@288` — replace-or-justify-sleep.
- `aNewerOperationKeepsItsPageWhenTheSignInEnds`: `.timeLimit(@298`, `Task.sleep(@304` — replace-or-justify-sleep.
- `aFailedLoadEndsAHiddenSignInButNotTheUsers`: `.timeLimit(@313`, `Task.sleep(@325` — replace-or-justify-sleep.
- `aCrashedPageStopsAHiddenSignInOrRestartsTheUsers`: `.timeLimit(@332` — hang-guard.
- `closingOrANewOperationEndsAStreamWaitingOnWebex`: `.timeLimit(@369`, `Task.sleep(@382`, `Task.sleep(@387`, `ContinuousClock(@391`, `clock.now@392`, `clock.now@403` — changed, replace-or-justify-sleep.
- `aMismatchedRecordingIsUnavailable`: `Date(@426` — hang-guard.

**BeepbarAppTests/WebexStreamResolverTests.swift**

- `cancellingMidRequestEndsAtOnce`: `.timeLimit(@245`, `Task.sleep(@252`, `ContinuousClock(@255`, `clock.now@256`, `clock.now@259` — changed, replace-or-justify-sleep.

**BeepbarBenchmarkKitTests/BenchmarkKitTests.swift**

- `cpuTimeIsReportedInNanoseconds`: `ContinuousClock(@30`, `clock.now@31`, `clock.now@35`, `clock.now@40` — retain-measurement.

**BeepbarBenchmarkKitTests/BenchmarkUpstreamTests.swift**

- `stalledClientTimesOut`: `ContinuousClock(@127`, `clock.now@128`, `clock.now@133` — retain-measurement.

**BeepbarBenchmarkKitTests/MemoryMeasurementTests.swift**

- `peakSamplerCatchesATransientAllocation`: `Thread.sleep(@47` — replace-or-justify-sleep, retain-measurement.

**BeepbarCoreTests/BoundedScriptCallTests.swift**

- `onlyTheFirstSignalSettlesAndTheRestAreRecordedAsLate`: `settle(@23`, `settle(@27`, `settle(@28` — retain-hang-guard-review-order.
- `anAnswerBeforeAnythingElseIsTheOutcome`: `settle(@37`, `settle(@38` — retain-hang-guard-review-order.
- `anAnswerInTimeIsNotOvertakenByTheTimer`: `Task.sleep(@118` — replace-or-justify-sleep.
- `lateSignalsAfterAnInterruptAreIgnored`: `Task.sleep(@130` — replace-or-justify-sleep.

**BeepbarCoreTests/DirectoryTraversalProfileTests.swift**

- `profileUnchangedCheck`: `ContinuousClock.now@54`, `ContinuousClock.now@56` — retain-measurement.

**BeepbarCoreTests/FileHashCancellationTests.swift**

- `releaseCancellationLatency`: `ContinuousClock(@179`, `clock.now@189` — hang-guard.

**BeepbarCoreTests/MetadataResponseTests.swift**

- `cancellationStopsReceptionAndAlreadyCancelledTaskDoesNotStart`: `Task.sleep(@86` — replace-or-justify-sleep.

**BeepbarCoreTests/NetworkPathReaderTests.swift**

- `cancellingTheWatchStopsTheMonitor`: `deadline@25`, `ContinuousClock.now@25`, `ContinuousClock.now@26`, `deadline@26` — hang-guard.
- `cancellationOfSilentProviderIsPromptAndCleansUp`: `ContinuousClock(@67`, `clock.now@68`, `clock.now@70` — changed.
- `cancellationDuringInstallationReleasesLateResources`: `ContinuousClock(@91`, `deadline@92`, `clock.now@92`, `clock.now@93`, `deadline@93` — changed.

**BeepbarCoreTests/PerformancePolicyTests.swift**

- `progressThrottleLimitsIntermediateUpdatesAndAlwaysDeliversFinal`: `ContinuousClock(@6`, `clock.now@7` — retain-time-behavior.
- `progressThrottleRejectsRegressionsAndResets`: `ContinuousClock(@29`, `clock.now@30` — retain-time-behavior.

**BeepbarCoreTests/RecmanSessionVaultTests.swift**

- `aSaveFromBeforeADiscardIsRefusedAtCommit`: `waitUntilHeld(@121`, `settle(@130` — retain-hang-guard-review-order.
- `operationsRunInTheOrderTheyWereEnqueued`: `waitUntilHeld(@148`, `waitUntilHeld(@157` — retain-hang-guard-review-order.
- `aDiscardForgetsTheSessionItRemoves`: `waitUntilHeld(@202`, `settle(@214` — retain-hang-guard-review-order.
- `aRetryKeepsASessionSavedSinceTheDiscard`: `waitUntilHeld(@252` — retain-hang-guard-review-order.
- `anEmailUpdateFromBeforeADiscardIsRefused`: `waitUntilHeld(@357`, `settle(@361` — retain-hang-guard-review-order.
- `fileWorkNeverRunsOnTheMainThread`: `settle(@389` — retain-hang-guard-review-order.

**BeepbarCoreTests/RecordingNextToWatchTests.swift**

- `menuPersistenceKeepsOnlyPlaybackFields`: `Date(@26` — hang-guard.

**BeepbarCoreTests/RootOperationGateTests.swift**

- `releasesTheLeaseWhenAnOperationIsCancelled`: `Task.sleep(@24`, `Task.sleep(@28` — replace-or-justify-sleep.

**BeepbarCoreTests/SyncCoordinatorEndToEndTests.swift**

- `defersLegacyMigrationWithOpenConflictWithoutCreatingASuffix`: `Date(@396` — hang-guard.
- `cancellationLeavesNoBaselineOrStagingArtifacts`: `Task.sleep(@710` — replace-or-justify-sleep.
- `cancellationDuringStagingPreservesExistingFileAndBaseline`: `Task.sleep(@751` — replace-or-justify-sleep.
- `missingRootAndConcurrentRunsDoNotMutateState`: `Task.sleep(@765` — replace-or-justify-sleep.

**BeepbarCoreTests/SyncDatabaseTests.swift**

- `writeWaitsForABusyDatabaseInsteadOfFailingImmediately`: `Task.sleep(@131` — replace-or-justify-sleep.

</details>

<details>
<summary>Reproduce the scan</summary>

Run from a checkout containing `32472a9`; the script reads Git objects only and prints TSV.

```sh
python3 - <<'PY'
import subprocess,re,collections
BASE='32472a9'
files=subprocess.check_output(['git','ls-tree','-r','--name-only',BASE,'Tests'],text=True).splitlines()
attr=re.compile(r'@Test\b(?:(?!\bfunc\b|@Test).){0,800}?\bfunc\s+(\w+)',re.S)
# Match call sites rather than declarations or arbitrary uses of these words.
pat=re.compile(r'\b(?:Task\.sleep|Thread\.sleep|usleep|sleep|asyncAfter|waitUntil|waitUntilHeld|waitForCalls|waitForChoice|waitForCancellation|untilPending|untilBlank|eventually|settle|drainTasks)\s*\(|\b(?:ContinuousClock|Date)\s*\(|\b(?:ContinuousClock\.now|clock\.now|deadline)\b|\.timeLimit\s*\(')
# Tokenize braces while ignoring comments and strings; Swift interpolation is treated as part of a string.
def body_end(s,start):
 i=start; depth=0; state='code'; nesting=0
 while i<len(s):
  if state=='line':
   if s[i]=='\n': state='code'
   i+=1;continue
  if state=='block':
   if s.startswith('/*',i): nesting+=1;i+=2;continue
   if s.startswith('*/',i):
    nesting-=1;i+=2
    if not nesting: state='code'
    continue
   i+=1;continue
  if state=='string':
   if s[i]=='\\':i+=2;continue
   if s[i]=='"':state='code'
   i+=1;continue
  if state=='triple':
   if s.startswith('"""',i):state='code';i+=3;continue
   i+=1;continue
  if s.startswith('//',i):state='line';i+=2;continue
  if s.startswith('/*',i):state='block';nesting=1;i+=2;continue
  if s.startswith('"""',i):state='triple';i+=3;continue
  if s[i]=='"':state='string';i+=1;continue
  if s[i]=='{':depth+=1
  if s[i]=='}':
   depth-=1
   if depth==0:return i+1
  i+=1
 raise RuntimeError('unclosed body')
changed={'anIsolationEndedWhileTheOriginalIsCopiedLeavesNoOriginal','menuQuitCancelsTheSyncAndGoesOnOnceItStops','menuQuitGivesUpWaitingAfterTheTimeout','cappedWaitReturnsOnWhicheverComesFirst','aScriptThatNeverAnswersEndsAtTheTimeout','closingEndsAScriptInFlight','aNewOperationEndsThePreviousScript','cancellingTheAwaitingTaskEndsTheScript','closingReleasesTheWebViewDespiteAStalledScript','slowOversizedOrBrokenAnswersFail','aCoursePictureArrivingAfterAnAccountChangeIsDropped','theSchedulerCompletesWhileTheFollowUpIsStillBlocked','cancellingAnAutomaticRunStopsTheFollowUpPromptly','droppingTheScheduleKeepsAManualRefreshTheAutomaticRunJoined','droppingTheScheduleKeepsAnAutomaticRefreshAManualSyncJoined','aManualSyncDoesNotMergeIntoAFollowUpTheDroppedScheduleCancelled','menuQuitDoesNotWaitForTheFollowUp','closingOrANewOperationEndsAStreamWaitingOnWebex','cancellingMidRequestEndsAtOnce','cancellationOfSilentProviderIsPromptAndCleansUp','cancellationDuringInstallationReleasesLateResources'}
rows=[]; ntests=0; errors=[]
for path in files:
 if not path.endswith('.swift'):continue
 src=subprocess.check_output(['git','show',f'{BASE}:{path}'],text=True)
 for m in attr.finditer(src):
  ntests+=1; name=m.group(1); start=src.find('{',m.end())
  if start<0: errors.append((path,name));continue
  try:end=body_end(src,start)
  except RuntimeError:errors.append((path,name));continue
  # Ignore comments and string literals for matching, while retaining source offsets.
  raw=src[m.start():end]; cleaned=list(raw);i=0;state='code';nest=0
  while i<len(raw):
   if state=='line':
    if raw[i]=='\n':state='code'
    else:cleaned[i]=' '
    i+=1;continue
   if state=='block':
    if raw.startswith('/*',i):cleaned[i:i+2]='  ';nest+=1;i+=2;continue
    if raw.startswith('*/',i):cleaned[i:i+2]='  ';nest-=1;i+=2;state='code' if nest==0 else 'block';continue
    if raw[i]!='\n':cleaned[i]=' '
    i+=1;continue
   if state in ('string','triple'):
    if state=='triple' and raw.startswith('"""',i):cleaned[i:i+3]='   ';i+=3;state='code';continue
    if state=='string' and raw[i]=='\\':cleaned[i:i+2]='  ';i+=2;continue
    if state=='string' and raw[i]=='"':cleaned[i]=' ';i+=1;state='code';continue
    if raw[i]!='\n':cleaned[i]=' '
    i+=1;continue
   if raw.startswith('//',i):cleaned[i:i+2]='  ';state='line';i+=2;continue
   if raw.startswith('/*',i):cleaned[i:i+2]='  ';state='block';nest=1;i+=2;continue
   if raw.startswith('"""',i):cleaned[i:i+3]='   ';state='triple';i+=3;continue
   if raw[i]=='"':cleaned[i]=' ';state='string';i+=1;continue
   i+=1
  clean=''.join(cleaned); hits=[]
  for h in pat.finditer(clean):
   word=h.group().strip()
   if word.startswith('Date(') and clean[h.start():h.start()+40].startswith('Date(timeIntervalSince'): continue
   line=src.count('\n',0,m.start()+h.start())+1
   hits.append(f'{word}@{line}')
  if not hits and name not in changed: continue
  # Dispositions identify review treatment, not a claim that every deadline is harmless.
  kinds=set()
  if name in changed:kinds.add('changed')
  if re.search(r'Benchmark|Measurement|Profile',path):kinds.add('retain-measurement')
  if re.search(r'Timeout|timeout|Cadence|cadence|Throttle|throttl|Duration|duration',name):kinds.add('retain-time-behavior')
  if any(re.match(r'(Task\.sleep|Thread\.sleep|usleep|sleep|asyncAfter)\s*\(',h) for h in hits):kinds.add('replace-or-justify-sleep')
  if any(re.match(r'(wait|until|eventually|settle|drainTasks|outcome)',h) for h in hits):kinds.add('retain-hang-guard-review-order')
  if not kinds:kinds.add('hang-guard')
  rows.append((path,name,','.join(hits) or 'changed: no heuristic hit','/'.join(sorted(kinds))))
print('TEST_DECLARATIONS',ntests,'MATCHING_TESTS',len(rows),'CALL_SITES',sum(len(x[2].split(',')) for x in rows),'ERRORS',errors)
for r in rows: print('\t'.join(r))
PY
```

</details>
