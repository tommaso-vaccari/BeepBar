import Foundation
import BeepbarCore

extension WeBeepAuthenticationController {
    /// Reads already available catalog data without starting a refresh or changing user state.
    @MainActor func terminalCatalog(_ command: TerminalCommand) async -> TerminalResponse {
        switch command.name {
        case "courses":
            let freshness: String
            var fields: [String: Any] = [:]
            let snapshot = await terminalCourseSnapshot()
            switch snapshot.freshness {
            case .unknown:
                return TerminalOutput.error("unavailable", tr("L’elenco dei corsi non è disponibile in locale.", "The course list is not available locally."))
            case .current:
                freshness = "current"
            case .saved(let date):
                freshness = "cached"
                fields["savedAt"] = TerminalOutput.date(date)
            }
            fields["freshness"] = freshness
            let rows: [[String: Any]] = snapshot.courses.sorted { $0.id < $1.id }.filter {
                command.id == nil || String($0.id) == command.id
            }.map { course in
                let folder = snapshot.folders[course.id] ?? folder(for: course)
                var row: [String: Any] = ["id": String(course.id), "name": course.displayName,
                    "shortName": course.shortName, "selected": enabledCourseIDs.contains(course.id), "folder": folder]
                if let rootURL { row["localPath"] = rootURL.appendingPathComponent(folder).path }
                return row
            }
            return TerminalOutput.page(rows, command: command, fields: fields)
        case "conflicts":
            do {
                let pending = try await terminalPendingChoices()
                var rows: [[String: Any]] = pending.conflicts.map { conflict in
                    ["id": conflict.id.uuidString, "type": "conflict", "path": conflict.relativePath.value,
                     "materialId": conflict.remoteID,
                     "incomingPath": conflict.incomingPath.value, "detectedAt": TerminalOutput.date(conflict.detectedAt),
                     "choices": [ConflictResolution.keepLocal.rawValue, ConflictResolution.useRemote.rawValue]]
                }
                rows += pending.changes.map { change in
                    var row: [String: Any] = ["id": change.id.uuidString, "type": "remote_change",
                        "kind": change.kind.rawValue, "courseId": String(change.courseID), "materialId": change.remoteID,
                        "path": change.relativePath.value, "locallyModified": change.isLocallyModified,
                        "detectedAt": TerminalOutput.date(change.detectedAt),
                        "choices": RemoteChangeAction.available(for: change.kind).map(\.rawValue)]
                    if let target = change.targetPath { row["targetPath"] = target.value }
                    return row
                }
                rows.sort { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
                if let id = command.id { rows = rows.filter { ($0["id"] as? String)?.lowercased() == id.lowercased() } }
                return TerminalOutput.page(rows, command: command)
            } catch {
                return TerminalOutput.error("unavailable", tr("Impossibile leggere le scelte in sospeso.", "Pending choices could not be read."))
            }
        case "recordings":
            guard let controller = recordingsIfCreated, controller.isEnabled else {
                return TerminalOutput.error("unavailable", tr("Gli elenchi delle registrazioni non sono disponibili in locale.", "Recording listings are not available locally."))
            }
            let snapshot = await terminalCourseSnapshot()
            let selectedCourses = snapshot.courses.filter { course in command.courseID == nil || course.id == command.courseID }
            var rows: [[String: Any]] = []
            var total = 0
            var unavailable: [String] = []
            var catalog: [[String: Any]] = []
            func pageSlice<T>(_ items: [T]) -> ArraySlice<T> {
                let start = min(items.count, max(0, command.offset - total))
                let end = start + min(items.count - start, command.limit - rows.count)
                total += items.count
                return items[start..<end]
            }
            for course in selectedCourses.sorted(by: { $0.id < $1.id }) {
                guard let key = RecmanCourseKey(course: course), let listing = controller.listing(for: key),
                      let recordings = listing.recordings else {
                    unavailable.append(String(course.id))
                    continue
                }
                let fresh = listing.problem == nil && listing.updatedAt.map { Date().timeIntervalSince($0) < RecordingsController.freshness } == true
                var coverage: [String: Any] = ["courseId": String(course.id), "freshness": fresh ? "current" : "cached"]
                if let date = listing.updatedAt { coverage["updatedAt"] = TerminalOutput.date(date) }
                catalog.append(coverage)
                for recording in pageSlice(recordings) {
                    var row: [String: Any] = ["id": recording.id, "courseId": String(course.id),
                        "title": recording.title, "recordedAt": TerminalOutput.date(recording.recordedAt),
                        "kind": recording.kind, "duration": recording.duration, "source": "archive",
                        "freshness": fresh ? "current" : "cached"]
                    if let size = recording.size { row["size"] = size }
                    if let date = listing.updatedAt { row["updatedAt"] = TerminalOutput.date(date) }
                    if controller.watchProgress.isKnown(recording) {
                        row["progress"] = controller.watchProgress.fraction(for: recording)
                        row["completed"] = controller.watchProgress.isCompleted(recording)
                    }
                    rows.append(row)
                }
            }
            let linked = controller.manualLessons.lessons.filter { command.courseID == nil || command.courseID == $0.courseID }
            for lesson in pageSlice(linked) {
                let recording = lesson.recording
                var row: [String: Any] = ["id": lesson.id, "title": recording.title, "source": "linked",
                    "kind": recording.kind, "duration": recording.duration, "addedAt": TerminalOutput.date(lesson.addedAt),
                    "freshness": "local", "watchlisted": lesson.isWatchlisted]
                if let courseID = lesson.courseID { row["courseId"] = String(courseID) }
                if let date = lesson.recordedAt { row["recordedAt"] = TerminalOutput.date(date) }
                if controller.watchProgress.isKnown(recording) {
                    row["progress"] = controller.watchProgress.fraction(for: recording)
                    row["completed"] = controller.watchProgress.isCompleted(recording)
                }
                rows.append(row)
            }
            if catalog.isEmpty && total == 0 {
                return TerminalOutput.error("unavailable", tr("Gli elenchi delle registrazioni non sono disponibili in locale.", "Recording listings are not available locally."))
            }
            return TerminalOutput.page(rows, total: total, command: command, fields: [
                "courseListAvailable": snapshot.freshness != .unknown,
                "unavailableCourseIds": unavailable, "listingCoverage": catalog
            ])
        default:
            return TerminalOutput.error("unknown_command", tr("Comando del catalogo sconosciuto.", "Unknown catalog command."))
        }
    }
}
