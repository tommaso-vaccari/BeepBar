import AppKit
import SwiftUI
import Testing
@testable import BeepbarApp

/// The readiness marker ships in the normal app on the first row of Courses and Recordings, and
/// which row is first changes at runtime. Moving the marker must not rebuild a row: a modifier
/// that branches on `enabled` gives the marked row another structural identity and discards its
/// `@State`, e.g. a course rename being typed when a refresh reorders the list (#136 review).
@MainActor struct UIContentReadinessTests {
    @MainActor final class Toggle: ObservableObject { @Published var enabled = true }
    /// Counts state creations: SwiftUI evaluates a `StateObject`'s initial value only when it
    /// creates new storage for the view, so a second creation means the row was rebuilt.
    @MainActor final class Counter { var created = 0 }
    @MainActor final class Probe: ObservableObject { init(_ counter: Counter) { counter.created += 1 } }

    private struct Row: View {
        @StateObject private var probe: Probe
        init(counter: Counter) { _probe = StateObject(wrappedValue: Probe(counter)) }
        var body: some View { Text("Synthetic row") }
    }

    private struct Host: View {
        @ObservedObject var toggle: Toggle
        let counter: Counter
        var body: some View { Row(counter: counter).uiContentReady(.courses, enabled: toggle.enabled) }
    }

    /// Flips the marker off and on again on a hosted row and proves its state storage survives.
    @Test func movingTheMarkerKeepsTheRowState() async throws {
        let toggle = Toggle()
        let counter = Counter()
        let host = NSHostingView(rootView: Host(toggle: toggle, counter: counter))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 0
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(counter.created == 1)
        for enabled in [false, true] {
            toggle.enabled = enabled
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
        }
        #expect(counter.created == 1, "the row was rebuilt \(counter.created - 1) time(s) when the marker moved")
    }
}
