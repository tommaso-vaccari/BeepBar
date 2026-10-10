import Foundation

/// Invalid benchmark input, reported as usage with exit status 64.
public enum CLIError: Error {
    case usage(String)
}

/// Validates command options before any benchmark work or output-directory creation.
public struct BenchmarkOptions {
    public private(set) var values: [String: String] = [:]
    public private(set) var flags: Set<String> = []

    public init(_ arguments: ArraySlice<String>, command: String) throws {
        let metadata: Set<String> = ["commit", "dirty"]
        let sampling: Set<String> = ["runs", "warmup"]
        let allowed: Set<String>
        switch command {
        case "unchanged": allowed = metadata.union(sampling).union(["files", "courses", "json"])
        case "large-update": allowed = metadata.union(sampling).union(["size-mb", "json"])
        case "cancel": allowed = metadata.union(sampling).union(["size-mb", "fraction", "rate-mbps", "json"])
        case "baseline": allowed = metadata.union(sampling).union(["out"])
        case "idle": allowed = metadata.union(["pid", "minutes", "interval-seconds", "json"])
        default: throw CLIError.usage("unknown command \(command)")
        }
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            guard argument.hasPrefix("--") else { throw CLIError.usage("unexpected argument \(argument)") }
            let name = String(argument.dropFirst(2))
            guard allowed.contains(name) else { throw CLIError.usage("unknown option \(argument) for \(command)") }
            guard values[name] == nil, !flags.contains(name) else { throw CLIError.usage("duplicate option \(argument)") }
            if name == "dirty" { flags.insert(name); continue }
            guard let value = iterator.next(), !value.hasPrefix("--"), !value.isEmpty else {
                throw CLIError.usage("missing value for \(argument)")
            }
            values[name] = value
        }
        // Validate eagerly: baseline creates its directory before reading its sampling values.
        for name in ["runs", "warmup", "files", "courses", "size-mb", "rate-mbps"] where values[name] != nil {
            let value = try int(name, 1, allowZero: name == "warmup")
            if ["size-mb", "rate-mbps"].contains(name), value > Int64.max / 1_048_576 {
                throw CLIError.usage("--\(name) is too large")
            }
        }
        for name in ["fraction", "minutes", "interval-seconds"] where values[name] != nil {
            let value = try double(name, 1)
            if name == "fraction", value > 1 { throw CLIError.usage("--fraction must be at most 1") }
            if name == "minutes", !(value * 60).isFinite { throw CLIError.usage("--minutes is too large") }
        }
        if command != "idle" {
            let runs = try int("runs", 5)
            let warmup = try int("warmup", 1, allowZero: true)
            guard !runs.addingReportingOverflow(warmup).overflow else {
                throw CLIError.usage("--runs plus --warmup is too large")
            }
        }
        if command == "unchanged" {
            let files = try int("files", 1000)
            let courses: Int
            if values["courses"] != nil {
                courses = try int("courses", 10)
            } else {
                guard !files.addingReportingOverflow(999).overflow else { throw CLIError.usage("--files is too large") }
                courses = max(10, (files + 999) / 1000)
            }
            // CorpusSpec rounds up using (files + courses - 1), including the intermediate sum.
            guard !files.addingReportingOverflow(courses).overflow else {
                throw CLIError.usage("--files plus --courses is too large")
            }
        }
        if command == "idle" {
            guard let text = values["pid"], let pid = Int32(text), pid > 0 else {
                throw CLIError.usage("idle needs --pid with a positive 32-bit integer")
            }
        }
    }

    public func int(_ name: String, _ fallback: Int, allowZero: Bool = false) throws -> Int {
        guard let text = values[name] else { return fallback }
        guard let value = Int(text), value > 0 || (allowZero && value == 0) else { throw CLIError.usage("--\(name) needs a \(allowZero ? "non-negative" : "positive") integer") }
        return value
    }

    public func double(_ name: String, _ fallback: Double) throws -> Double {
        guard let text = values[name] else { return fallback }
        guard let value = Double(text), value > 0, value.isFinite else { throw CLIError.usage("--\(name) needs a positive number") }
        return value
    }
}
