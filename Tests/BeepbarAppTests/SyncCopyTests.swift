import BeepbarCore
import Foundation
import Testing
@testable import BeepbarApp

struct SyncCopyTests {
    @Test func conflictTitleUsesSingularForOne() {
        #expect(SyncCopy.conflictsTitle(1) == "1 conflitto da risolvere")
        #expect(SyncCopy.conflictsTitle(3) == "3 conflitti da risolvere")
        #expect(AppSyncState.conflicts(1, nil).title == "1 conflitto da risolvere")
    }

    @Test func notificationBodiesUseSingularAndPlural() {
        #expect(SyncCopy.conflictNotificationBody(1) == "BeepBar ha conservato separatamente 1 versione remota.")
        #expect(SyncCopy.conflictNotificationBody(2) == "BeepBar ha conservato separatamente 2 versioni remote.")
        #expect(SyncCopy.newMaterialsNotificationBody(1) == "BeepBar ha aggiunto 1 materiale nella cartella scelta.")
        #expect(SyncCopy.newMaterialsNotificationBody(4) == "BeepBar ha aggiunto 4 materiali nella cartella scelta.")
    }

    @Test func partialDetailSeparatesInaccessibleCoursesFromFailedFiles() {
        let course = CourseSyncCount(courseID: 2, courseFolder: "Analisi", added: 0, updated: 0, courseFailure: "Corso non accessibile su WeBeep.")
        let summary = SyncCompletionSummary(completedAt: Date(), added: 3, updated: 0, unchanged: 0, preservedLocal: 0, conflicts: 0, failures: 3, perCourse: [course])
        #expect(summary.partialDetail == "1 corso non accessibile. 2 materiali non aggiornati. I file esistenti sono al sicuro.")
        #expect(summary.affectedCourses.map(\.courseID) == [2])
        #expect(SyncCopy.partialDetail(failedFiles: 1, failedCourses: 0) == "1 materiale non aggiornato. I file esistenti sono al sicuro.")
        #expect(SyncCopy.partialDetail(failedFiles: 0, failedCourses: 2) == "2 corsi non accessibili. I file esistenti sono al sicuro.")
    }

    @Test func filesMovedToFollowMoodleAreCountedButKeptOnesAreNot() {
        let moved = (0..<3).map { MovedSyncItem(id: "m\($0)", name: "\($0).pdf", folder: "Lab 0", outcome: .moved) }
        let kept = MovedSyncItem(id: "k", name: "k.pdf", folder: "Lab 0", outcome: .keptEdited)
        let course = CourseSyncCount(courseID: 1, courseFolder: "Analisi", added: 0, updated: 0, movedItems: moved + [kept])
        let summary = SyncCompletionSummary(completedAt: Date(), added: 0, updated: 0, unchanged: 0, preservedLocal: 0, conflicts: 0, failures: 0, perCourse: [course])
        #expect(summary.moved == 3)
        #expect(summary.compactDetail == "Nessuna novità")
        #expect(summary.detail == "Nessun nuovo materiale. 3 file spostati nella loro nuova cartella.")
        #expect(summary.affectedCourses.map(\.courseID) == [1])
        #expect(course.movedLabel == "3 spostati")
        #expect(course.keptInPlaceLabel == "1 da scegliere in Conflitti")
    }

    @Test func summarySavedByAnOlderVersionStillDecodes() throws {
        let json = #"{"completedAt":0,"added":1,"updated":0,"unchanged":0,"preservedLocal":0,"conflicts":0,"failures":0,"perCourse":[{"courseID":1,"courseFolder":"A","added":1,"updated":0}]}"#
        let summary = try JSONDecoder().decode(SyncCompletionSummary.self, from: Data(json.utf8))
        #expect(summary.perCourse.first?.courseFailure == nil)
    }

    @Test func automaticSyncOnlyTargetsCoursesStillEnrolled() {
        let root = UUID()
        let scopes = [
            SyncScope(rootID: root, courseID: 1, displayName: "A", localFolder: "a", enabled: true),
            SyncScope(rootID: root, courseID: 2, displayName: "B", localFolder: "b", enabled: true),
            SyncScope(rootID: root, courseID: 3, displayName: "C", localFolder: "c", enabled: false),
        ]
        let targets = WeBeepAuthenticationController.automaticTargets(scopes: scopes, enrolledCourseIDs: [1, 3])
        #expect(targets == [SyncTarget(courseID: 1, localFolder: "a")])
    }

    @Test func moduleFolderErrorsAreShownInItalian() {
        #expect(WeBeepAuthenticationController.moduleFolderErrorMessage(RootOperationGateError.busy(.syncing(UUID()))) == "Un'altra operazione è in corso sulla cartella. Riprova tra poco.")
        #expect(WeBeepAuthenticationController.moduleFolderErrorMessage(ModulePathMigrationError.planChanged) == ModulePathMigrationError.planChanged.errorDescription)
        #expect(WeBeepAuthenticationController.moduleFolderErrorMessage(WeBeepAPIError.network(.offline)) == "Connessione assente. Riprova quando sei online.")
        #expect(WeBeepAuthenticationController.moduleFolderErrorMessage(SyncDatabaseError.execution) == "Operazione non riuscita. Riprova.")
    }
}
