import Foundation
import BeepbarCore

/// Versioned arguments and JSON output shared by the terminal commands.
struct TerminalCommand {
    static let syntax = [
        "capabilities", "doctor", "status", "sync [--wait]",
        "runs [RUN_ID]", "changes (--since RUN_ID | --run RUN_ID) [--course COURSE_ID]",
        "courses [COURSE_ID]", "conflicts [CONFLICT_ID]", "recordings [--course COURSE_ID]"
    ]
    static let names: Set<String> = ["capabilities", "doctor", "status", "sync", "runs", "changes", "courses", "conflicts", "recordings"]

    let name: String
    var id: String?
    var courseID: Int64?
    var wait = false
    var includeRun = false
    var offset = 0
    var limit = 50

    init?(_ arguments: [String]) {
        guard let command = arguments.first, Self.names.contains(command) else { return nil }
        name = command
        var args = arguments.dropFirst().makeIterator()
        var seen: Set<String> = []
        let list = ["runs", "changes", "courses", "conflicts", "recordings"].contains(command)
        while let arg = args.next() {
            guard seen.insert(arg).inserted else { return nil }
            switch arg {
            case "--json": break
            case "--wait" where command == "sync": wait = true
            case "--offset" where list:
                guard let raw = args.next(), let value = Int(raw), value >= 0 else { return nil }
                offset = value
            case "--limit" where list:
                guard let raw = args.next(), let value = Int(raw), (1...200).contains(value) else { return nil }
                limit = value
            case "--course" where command == "recordings" || command == "changes":
                guard let raw = args.next(), let value = Int64(raw), value > 0 else { return nil }
                courseID = value
            case "--since", "--run":
                guard command == "changes", id == nil, let value = args.next(), let uuid = UUID(uuidString: value) else { return nil }
                id = uuid.uuidString
                includeRun = arg == "--run"
            default:
                guard id == nil else { return nil }
                switch command {
                case "courses":
                    guard let value = Int64(arg), value > 0 else { return nil }
                    id = String(value)
                case "runs", "conflicts":
                    guard let value = UUID(uuidString: arg) else { return nil }
                    id = value.uuidString
                default: return nil
                }
            }
        }
        if command == "changes", id == nil { return nil }
    }
}

enum TerminalOutput {
    static let schemaVersion = TerminalResponse.schemaVersion

    static func success(_ fields: [String: Any], exitCode: Int32 = 0) -> TerminalResponse {
        var envelope = fields
        envelope["schemaVersion"] = schemaVersion
        guard let json = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return error("encoding_failed", tr("Impossibile codificare la risposta.", "Couldn't encode the response."))
        }
        return TerminalResponse(exitCode: exitCode, json: json)
    }

    static func error(_ code: String, _ message: String, exitCode: Int32 = 1) -> TerminalResponse {
        TerminalResponse.failure(code: code, message: message, exitCode: exitCode)
    }

    static func date(_ date: Date) -> String { date.ISO8601Format() }

    static func page(_ rows: [[String: Any]], command: TerminalCommand, fields: [String: Any] = [:]) -> TerminalResponse {
        let offset = min(command.offset, rows.count)
        let end = offset + min(command.limit, rows.count - offset)
        return page(Array(rows[offset..<end]), total: rows.count, command: command, fields: fields)
    }

    static func page(_ items: [[String: Any]], total: Int, command: TerminalCommand, fields: [String: Any] = [:]) -> TerminalResponse {
        var payload = fields
        payload["items"] = items
        payload["total"] = total
        let end = min(command.offset, total) + items.count
        payload["nextOffset"] = end < total ? (end as Any) : NSNull()
        return success(payload)
    }
}

/// Holds finished runs for the current app session and identity. The summary already produced for
/// Activity supplies the file changes, without a second sync or filesystem scan.
struct TerminalRun {
    let id: UUID
    let finishedAt: Date
    let outcome: String
    let reason: String?
    let summary: SyncCompletionSummary?
    let pendingChoiceCount: Int?

    init(id: UUID, finishedAt: Date = Date(), end: MaterialsRunEnd, summary: SyncCompletionSummary?, pendingChoiceCount: Int? = nil) {
        self.id = id
        self.finishedAt = finishedAt
        self.summary = summary
        self.pendingChoiceCount = pendingChoiceCount
        (outcome, reason) = switch end {
        case .completed(let conflicts, let failures):
            (conflicts > 0 || failures > 0 || (pendingChoiceCount ?? 0) > 0 ? "completed_with_issues" : "completed", nil)
        case .cancelled, .scheduleChanged: ("cancelled", nil)
        case .superseded: ("superseded", "identity_changed")
        case .serviceFailure(let error): ("failed", Self.serviceReason(SyncServiceFailure(error)))
        case .pendingChoicesUnreadable: ("failed", "pending_choices_unreadable")
        case .localFailure: ("failed", "local_failure")
        case .pausedMidRun(let pause): ("paused", Self.pauseReason(pause))
        case .notRun, .unconfigured: ("blocked", "unconfigured")
        case .deferredWhileBusy: ("blocked", "folder_busy")
        case .credentialUnavailable: ("blocked", "credential_unavailable")
        }
    }

    var fields: [String: Any] {
        var fields: [String: Any] = [
            "runId": id.uuidString, "finishedAt": TerminalOutput.date(finishedAt), "outcome": outcome
        ]
        fields["reason"] = reason
        fields["pendingChoiceCount"] = pendingChoiceCount
        if let summary { fields["counts"] = Self.counts(summary) }
        return fields
    }

    var exitCode: Int32 {
        switch outcome {
        case "completed": 0
        case "completed_with_issues": 3
        case "cancelled", "superseded": 4
        default: 1
        }
    }

    static func counts(_ summary: SyncCompletionSummary) -> [String: Int] {
        ["added": summary.added, "updated": summary.updated, "moved": summary.perCourse.reduce(0) { $0 + $1.moved },
         "unchanged": summary.unchanged, "preservedLocal": summary.preservedLocal,
         "conflicts": summary.conflicts, "failures": summary.failures]
    }

    static func serviceReason(_ failure: SyncServiceFailure) -> String {
        switch failure {
        case .authenticationExpired: "sign_in_expired"
        case .connectivity: "offline"
        case .serviceUnavailable: "service_unavailable"
        case .incompatibleResponse: "incompatible_response"
        }
    }

    static func pauseReason(_ pause: DataSaverPause) -> String {
        switch pause {
        case .hotspot: "hotspot"
        case .lowDataMode: "low_data_mode"
        }
    }

    static func changes(_ runs: [TerminalRun], command: TerminalCommand) -> TerminalResponse {
        var items: [[String: Any]] = []
        var total = 0
        for run in runs {
            guard let summary = run.summary else { continue }
            for course in summary.perCourse where command.courseID == nil || command.courseID == course.courseID {
                func add<T>(_ group: [T], fields: (T) -> [String: Any]) {
                    defer { total += group.count }
                    let start = max(0, command.offset - total)
                    guard start < group.count, items.count < command.limit else { return }
                    let end = start + min(group.count - start, command.limit - items.count)
                    for item in group[start..<end] {
                        var row = fields(item)
                        row["runId"] = run.id.uuidString
                        row["courseId"] = String(course.courseID)
                        row["courseFolder"] = course.courseFolder
                        items.append(row)
                    }
                }
                add(course.items) { ["id": $0.id, "name": $0.name, "kind": $0.kind == .added ? "added" : "updated"] }
                add(course.movedItems) { ["id": $0.id, "name": $0.name, "kind": $0.outcome == .moved ? "moved" : "move_conflict", "destinationFolder": $0.folder] }
                add(course.failedItems) { ["id": $0.id, "name": $0.name, "kind": "failed", "message": $0.reason] }
                if let failure = course.courseFailure {
                    add([failure]) { ["kind": "course_failed", "message": $0] }
                }
            }
        }
        // Failed or cancelled runs may have applied changes before they ended, and BeepBar has no
        // completed Activity summary for those runs.
        return TerminalOutput.page(items, total: total, command: command, fields: [
            "incompleteRunIds": runs.filter { $0.summary == nil }.map { $0.id.uuidString }
        ])
    }
}
