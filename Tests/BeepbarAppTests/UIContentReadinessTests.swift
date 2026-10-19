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
        /// The `enabled` value of each body run, so the test can wait for the flip to land.
        let rendered: (Bool) -> Void
        var body: some View {
            let _ = rendered(toggle.enabled)
            Row(counter: counter).uiContentReady(.courses, enabled: toggle.enabled)
        }
    }

    /// Lays out until `condition` holds, at most 10 s: deadline polling on an observable fact,
    /// not a fixed sleep that a loaded runner can outlast (#223).
    private func settle(_ host: NSView, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        host.layoutSubtreeIfNeeded()
    }

    /// Flips the marker off and on again on a hosted row and proves its state storage survives.
    /// Each step waits for the fact it needs (the row created, the host's body run with the new
    /// value), never a fixed time (#223). Mutation: branch on `enabled` in the modifier and the
    /// row is created again.
    @Test func movingTheMarkerKeepsTheRowState() async throws {
        let toggle = Toggle()
        let counter = Counter()
        var rendered: [Bool] = []
        let host = NSHostingView(rootView: Host(toggle: toggle, counter: counter, rendered: { rendered.append($0) }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 0
        window.orderFront(nil)
        defer { window.close() }
        try await settle(host) { counter.created > 0 }
        #expect(counter.created == 1)
        for enabled in [false, true] {
            rendered = []
            toggle.enabled = enabled
            try await settle(host) { rendered.last == enabled }
            #expect(rendered.last == enabled, "the flip to \(enabled) never reached the host")
        }
        #expect(counter.created == 1, "the row was rebuilt \(counter.created - 1) time(s) when the marker moved")
    }
}
