import Foundation

// Refreshing the Recordings listings whenever the sync runs (owner decision 2026-10-12).
//
// After every materials sync, automatic or "Sincronizza ora", the app re-reads the Recman archive
// listing of each selected course (listings and seen/new state only: never a stream, never a
// download) in a follow-up that is independent of the materials run: it never changes the sync's
// status, never sends failure notifications and is not waited for by "Esci". This file holds the
// pure decisions behind it, so every combination is covered by Core tests:
// - `RecordingsSyncPolicy.decision` — whether the follow-up runs at all, and whether it ignores the
//   300 s freshness window;
// - `RecordingsSyncPolicy.newlyPublishedCount` — how many lectures a refresh found for the first
//   time, which drives the "N nuove registrazioni" notification.
// It lives in Domain, not in the Recordings folder, because it uses other Core types (network,
// university, sync failures) and `scripts/recman-probe.sh` compiles the Recordings folder alone.

/// How the materials run that precedes the recordings follow-up ended, as far as the follow-up
/// cares. The app maps its own result onto it.
///
/// Mapping table: every way a run ends in `WeBeepAuthenticationController.swift` and the case it
/// must map to. A path not listed here must be added to this table, never defaulted to `.synced`:
/// only a run that reached WeBeep and finished (or failed on WeBeep's side) may lead to Recman.
///
/// | Code path | Case |
/// |---|---|
/// | `completeSync`, finished, `summary.conflicts > 0` | `.conflicts` |
/// | `completeSync`, finished, `summary.failures > 0` (no conflicts) | `.partial` |
/// | `completeSync`, finished, otherwise | `.synced` |
/// | `completeSync`, `finishReconciliation` threw (pending choices unreadable) | `.localFailure` |
/// | `completeSync` / any path ending in `cancelledSync`, `CancellationError`, `runAutomaticSync` returning `.cancelled` | `.cancelled` |
/// | `failedSync(error: someWeBeepError)` | `.failed(SyncServiceFailure(error))` |
/// | `failedSync(error: nil)` (a non-WeBeep error, e.g. `SyncDatabaseError.open`) | `.localFailure` |
/// | `runAutomaticSync`, `pausedMidRun` returned true | `.pausedByDataSaver(pause)` |
/// | `runAutomaticSync`, `AutomaticSyncPolicy.decision` not `.run` | `.notRun(thatDecision)` |
/// | `runAutomaticSync`, schedule changed while reading the network (`schedulerGeneration` moved, returns `.finished` without running) | `.cancelled` (the run belongs to a schedule that no longer exists) |
/// | `runAutomaticSync`, no root/database (`guard let rootURL…` returns `.finished`) | `.notRun(.skipUnconfigured)` |
/// | `runAutomaticSync`, reading the enabled scopes failed (`.failed(.local)`) | `.localFailure` |
/// | `runAutomaticSync`, no enabled course (`no-enabled-courses`) | `.notRun(.skipUnconfigured)` |
/// | `runAutomaticSync`, `RootOperationGateError` → `deferredAutomaticSync` | `.notRun(.deferWhileBusy)` |
/// | `synchronizeNow`, `RootOperationGateError` → `busySync` (`.failed(.local)`) | `.localFailure` |
/// | `synchronizeNow`, recovery blocked, nothing selected (`.readyUnchecked`) or no folder (`.needsFolder`) | `.notRun(.skipUnconfigured)` |
/// | `synchronizeNow` returning early because another operation is active | no follow-up at all (nothing ended) |
/// | `handleCredentialStorageError` (`.absent`/`.corrupt`: effectively signed out, list forgotten; `.write`: `credentialUnavailable`), from `synchronizeNow` or `runAutomaticSync` | `.accountUnavailable` |
public enum RecordingsMaterialsOutcome: Sendable, Equatable {
    /// Completed, with or without new files.
    case synced
    /// Completed, with conflicts waiting for the student's choice.
    case conflicts
    /// Completed, but some materials couldn't be updated ("Materiali non aggiornati").
    case partial
    /// The materials run failed for this reason (WeBeep's side of things).
    case failed(SyncServiceFailure)
    /// The student or the app stopped it ("Annulla", sign-out, quit).
    case cancelled
    /// An automatic run that didn't start: Low Power Mode, another operation running, nothing
    /// configured, or Data Saver at the start (`AutomaticSyncPolicy.decision` other than `.run`).
    case notRun(AutomaticSyncDecision)
    /// An automatic run Data Saver stopped midway because the Mac moved to such a network.
    case pausedByDataSaver(DataSaverPause)
    /// The stored WeBeep credential is missing, unreadable or couldn't be written
    /// (`handleCredentialStorageError`): the account is gone or in doubt.
    case accountUnavailable
    /// A local failure unrelated to WeBeep (database, folder busy, pending choices unreadable):
    /// nothing about it is fixed by contacting Polimi.
    case localFailure
}

/// What started the sync. A manual "Sincronizza ora" re-lists every course ignoring the freshness
/// window; an automatic run respects it.
public enum RecordingsSyncTrigger: Sendable, Equatable {
    case manual
    case automatic
}

/// The Recordings page's access, mirrored from the app's `RecordingsAccess` without its problem
/// payload, so the gate can be decided here.
public enum RecordingsSyncAccess: Sendable, Equatable {
    /// The switch in Settings is off.
    case off
    /// On, and the saved Polimi session is assumed alive until a request says otherwise.
    case ready
    /// The Polimi sign-in is running (its window may be on screen).
    case signingIn
    /// The Polimi session is gone: only the student's own "Accedi con Polimi" brings it back.
    case needsSignIn
}

/// Why the follow-up doesn't run. Every skip is silent: none is shown as a failure, none sends a
/// notification, none touches the network.
public enum RecordingsSyncSkipReason: Sendable, Equatable {
    /// The Recordings switch is off (or the controller says `.off`).
    case switchedOff
    /// The account isn't Polimi's: Recman is Polimi's archive.
    case notPolimi
    /// No known account owner, so there is no namespace to publish seen state into.
    case ownerUnknown
    /// No selected course maps to a Recman course.
    case noCourses
    /// The materials run was cancelled: the student asked to stop.
    case materialsCancelled
    /// The automatic run was held back (Low Power Mode, busy): the scheduler retries later.
    case materialsDeferred
    /// Nothing configured to sync with (no account, folder or a blocked recovery).
    case unconfigured
    /// Data Saver held the materials run back, at the start or midway.
    case materialsPaused(DataSaverPause)
    /// The materials run found no network: the archive would fail the same way.
    case connectivity
    /// WeBeep's sign-in expired: the account is in doubt until the student signs in again.
    case authenticationExpired
    /// The stored WeBeep credential is missing, unreadable or unwritable.
    case accountUnavailable
    /// The materials run failed locally (database, busy folder, unreadable pending choices).
    case localFailure
    /// Data Saver is on and the Mac is now on a hotspot or a Low Data Mode network (re-read when
    /// the follow-up is about to start, since the network may have changed during the run).
    case dataSaver(DataSaverPause)
    /// The Polimi sign-in is running; the follow-up must not race it.
    case signingIn
    /// The Polimi session is gone. Skipping costs nothing and avoids a retry storm: the follow-up
    /// never opens the sign-in window on its own.
    case needsSignIn
}

/// Whether the follow-up runs.
public enum RecordingsSyncDecision: Sendable, Equatable {
    /// Re-list the courses. `force` ignores the freshness window (`RecordingsController.freshness`):
    /// true for a manual sync, false for an automatic one.
    case refresh(force: Bool)
    case skip(RecordingsSyncSkipReason)
}

/// The decisions behind refreshing Recordings at every sync.
public enum RecordingsSyncPolicy {
    /// Whether the recordings follow-up of a sync runs, and with which freshness rule.
    ///
    /// Order: the cheap, standing reasons first (switch, university, owner, access), then what the
    /// materials run says, then the courses, then the network. Rules, as approved:
    /// - A materials result about WeBeep's own service (synced, conflicts, partial, service
    ///   unavailable, incompatible response) does not block it: Recman is a different service.
    /// - No network, a cancellation, a deferred, paused or unconfigured run skip it, and so do an
    ///   unavailable WeBeep credential and a local failure (see `RecordingsMaterialsOutcome`'s table).
    /// - An expired WeBeep sign-in skips it too (not in the approved list; chosen because the
    ///   account is in doubt and the app is about to ask the student to sign in again).
    /// - `.signingIn` and `.needsSignIn` skip it at zero cost: the follow-up never asks the student.
    /// - Data Saver applies only to automatic runs, like for materials: "Sincronizza ora" always
    ///   downloads, on any network. `currentNetwork` must be read when the follow-up is about to
    ///   start, not reused from the start of the run.
    ///
    /// - Parameters:
    ///   - switchedOn: the Recordings switch in Settings.
    ///   - university: the selected site's university, nil when no site is selected.
    ///   - ownerKnown: whether the account owner (the seen-state namespace) is known.
    ///   - courseKeys: the Recman keys of the selected, synced courses.
    ///   - outcome: how the materials run ended.
    ///   - trigger: manual or automatic.
    ///   - dataSaverEnabled: the "Risparmio dati" setting.
    ///   - currentNetwork: the network now; nil when unknown (never a reason to pause).
    ///   - access: the Recordings page's access state.
    public static func decision(switchedOn: Bool,
                                university: MoodleUniversity?,
                                ownerKnown: Bool,
                                courseKeys: Set<RecmanCourseKey>,
                                outcome: RecordingsMaterialsOutcome,
                                trigger: RecordingsSyncTrigger,
                                dataSaverEnabled: Bool,
                                currentNetwork: NetworkPathConditions?,
                                access: RecordingsSyncAccess) -> RecordingsSyncDecision {
        guard switchedOn else { return .skip(.switchedOff) }
        guard university == .polimi else { return .skip(.notPolimi) }
        guard ownerKnown else { return .skip(.ownerUnknown) }
        switch access {
        case .off: return .skip(.switchedOff)
        case .signingIn: return .skip(.signingIn)
        case .needsSignIn: return .skip(.needsSignIn)
        case .ready: break
        }
        if let reason = skipReason(for: outcome) { return .skip(reason) }
        guard !courseKeys.isEmpty else { return .skip(.noCourses) }
        switch trigger {
        case .manual:
            return .refresh(force: true)
        case .automatic:
            if dataSaverEnabled, let pause = AutomaticSyncPolicy.dataSaverPause(for: currentNetwork) {
                return .skip(.dataSaver(pause))
            }
            return .refresh(force: false)
        }
    }

    /// Why a materials result skips the follow-up, nil when it doesn't.
    static func skipReason(for outcome: RecordingsMaterialsOutcome) -> RecordingsSyncSkipReason? {
        switch outcome {
        case .synced, .conflicts, .partial:
            return nil
        case .failed(let failure):
            switch failure {
            case .serviceUnavailable, .incompatibleResponse: return nil
            case .connectivity: return .connectivity
            case .authenticationExpired: return .authenticationExpired
            }
        case .cancelled:
            return .materialsCancelled
        case .notRun(let decision):
            switch decision {
            // `.run` contradicts "not run": treated as deferred rather than trusted, so a mapping
            // mistake in the app can only make the follow-up skip, never run unasked.
            case .run, .deferForLowPowerMode, .deferWhileBusy: return .materialsDeferred
            case .skipUnconfigured: return .unconfigured
            case .pause(let pause): return .materialsPaused(pause)
            }
        case .pausedByDataSaver(let pause):
            return .materialsPaused(pause)
        case .accountUnavailable:
            return .accountUnavailable
        case .localFailure:
            return .localFailure
        }
    }

    /// How many lectures of one course a refresh found for the first time: what the
    /// "N nuove registrazioni" notification counts. Never negative.
    ///
    /// - Baseline (`isBaseline`, the course's first complete listing, #106): 0. Everything in it
    ///   is marked seen, and a notification about the whole archive would be noise.
    /// - With the previous listing in memory (`previousIDs`): the IDs absent from it and still
    ///   unseen. A lecture the student already opened elsewhere isn't news.
    /// - After a relaunch (`previousIDs` nil) with a stored summary (`storedTotal`, the `total` the
    ///   last summary saved): the growth in the number of lectures, capped by the unseen count.
    ///   Known limitation: one lecture removed and one added in the same interval cancel out, so
    ///   that one isn't notified (it still gets its dot).
    /// - Neither known: 0. There is nothing to compare with, so nothing is claimed as new.
    ///
    /// - Parameters:
    ///   - previousIDs: the IDs of the listing held in memory before this refresh, nil when none.
    ///   - currentIDs: the IDs of the new, complete listing.
    ///   - seenIDs: the seen IDs after the refresh (the baseline included).
    ///   - isBaseline: whether this listing established the course's baseline.
    ///   - storedTotal: `CourseWatchSummary.total` of the saved summary, nil when none.
    public static func newlyPublishedCount(previousIDs: Set<String>?,
                                           currentIDs: Set<String>,
                                           seenIDs: Set<String>,
                                           isBaseline: Bool,
                                           storedTotal: Int?) -> Int {
        if isBaseline { return 0 }
        let unseen = currentIDs.subtracting(seenIDs)
        if let previousIDs {
            return unseen.subtracting(previousIDs).count
        }
        guard let storedTotal else { return 0 }
        // The stored total is untrusted (UserDefaults can be edited or damaged): clamping it at 0
        // keeps the subtraction from overflowing (`Int.min` would trap), and the unseen cap bounds
        // whatever a damaged negative value would claim.
        return max(0, min(currentIDs.count - max(0, storedTotal), unseen.count))
    }
}
