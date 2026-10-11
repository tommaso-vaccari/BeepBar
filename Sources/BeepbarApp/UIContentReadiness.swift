import SwiftUI
import BeepbarCore

/// A data row entering the SwiftUI hierarchy, measured separately from the window becoming key.
/// `onAppear` is a layout/readiness marker, not proof of compositor presentation; Instruments
/// and manual scrolling are still required to establish the UI's frame-time budget (#95).
enum UIContentKind: String, CaseIterable {
    case courses, activity, expandedActivity, recordings

    func trace() {
        switch self {
        case .courses: PerformanceTrace.shared.event("ui.firstCourseContent", category: .ui)
        case .activity: PerformanceTrace.shared.event("ui.firstActivityContent", category: .ui)
        case .expandedActivity: PerformanceTrace.shared.event("ui.firstExpandedActivityContent", category: .ui)
        case .recordings: PerformanceTrace.shared.event("ui.firstRecordingsContent", category: .ui)
        }
    }
}

private struct UIContentObserverKey: EnvironmentKey {
    static let defaultValue: (@MainActor (UIContentKind) -> Void)? = nil
}

extension EnvironmentValues {
    var uiContentObserver: (@MainActor (UIContentKind) -> Void)? {
        get { self[UIContentObserverKey.self] }
        set { self[UIContentObserverKey.self] = newValue }
    }
}

private struct UIContentReadiness: ViewModifier {
    let kind: UIContentKind
    let enabled: Bool
    @Environment(\.uiContentObserver) private var observer

    /// One view structure for every row, whatever `enabled` is. An `if enabled` branch would give
    /// the marked row a different structural identity, so when the first row changes (a refresh
    /// reorders courses, a filter hides a recording) both rows would be rebuilt and lose their
    /// `@State`, such as a course rename in progress. A `nil` action keeps unmarked rows free of
    /// callbacks. `UIContentReadinessTests` fails if the branch comes back (#95, #136).
    func body(content: Content) -> some View {
        content.onAppear(perform: enabled ? {
            kind.trace()
            observer?(kind)
        } : nil)
    }
}

extension View {
    /// Attach to a real populated row/header, never an empty/loading page or the shell itself.
    func uiContentReady(_ kind: UIContentKind, enabled: Bool = true) -> some View {
        modifier(UIContentReadiness(kind: kind, enabled: enabled))
    }
}

#if DEBUG
private struct UIFixtureExpansionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Only the isolated fixture uses this seam; ordinary app behavior stays collapsed.
    var uiFixtureExpandedActivity: Bool {
        get { self[UIFixtureExpansionKey.self] }
        set { self[UIFixtureExpansionKey.self] = newValue }
    }
}
#endif
