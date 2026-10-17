import Foundation
#if canImport(os)
import os
#endif

/// The language Beepbar's own text is shown in, chosen in onboarding and in Settings.
///
/// Strings are written inline as Italian/English pairs through `tr(_:_:)` rather than through a
/// String Catalog: a catalog is resolved from the bundle's language at launch, so switching would
/// need a relaunch, while this switches live. Core produces text off the main actor too (download
/// failure reasons, migration errors), so the current value sits behind a lock.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case italian = "it"
    case english = "en"

    public var id: String { rawValue }

    /// Always in the language itself, so someone stuck in the wrong one can still find theirs.
    public var nativeName: String {
        switch self {
        case .italian: "Italiano"
        case .english: "English"
        }
    }

    /// Used for dates and relative times ("9 minuti fa" / "9 minutes ago").
    public var locale: Locale {
        switch self {
        case .italian: Locale(identifier: "it_IT")
        case .english: Locale(identifier: "en_US")
        }
    }

    /// Italian for Italian-speaking systems, English for everything else.
    public static func preferred(from preferredLanguages: [String]) -> AppLanguage {
        guard let first = preferredLanguages.first else { return .italian }
        return first.lowercased().hasPrefix("it") ? .italian : .english
    }

    private static let storage = OSAllocatedUnfairLock(initialState: AppLanguage.italian)

    public static var current: AppLanguage {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// "1 file" / "3 files". Italian often needs no branch ("file" is invariable), English does.
public func englishCount(_ count: Int, _ one: String, _ many: String) -> String {
    "\(count) \(count == 1 ? one : many)"
}

/// Text that has to outlive the moment it was produced (stored errors, failure states): both
/// variants are kept so it still follows a later language switch instead of freezing in the
/// language that was active when it was stored.
public struct BilingualText: Equatable, Sendable {
    public let italian: String
    public let english: String

    public init(_ italian: String, _ english: String) {
        self.italian = italian
        self.english = english
    }

    public var text: String { tr(italian, english) }
}

/// Picks the variant for `AppLanguage.current`. Both are written at the call site so every phrase
/// sits next to its translation.
public func tr(_ italian: String, _ english: String) -> String {
    AppLanguage.current == .italian ? italian : english
}
