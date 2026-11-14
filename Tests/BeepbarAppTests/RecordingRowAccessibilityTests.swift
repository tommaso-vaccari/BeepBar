import AppKit
import SwiftUI
import Testing
import BeepbarCore
@testable import BeepbarApp

/// What VoiceOver finds in a Recordings row, read from the real accessibility tree of a hosted
/// `RecordingRow` (#196). SwiftUI builds that tree only for an assistive client, so the test turns
/// on `AXEnhancedUserInterface` for the app (the switch VoiceOver flips) while it runs and off
/// again afterwards. Serialized: that switch is process-global. Text is checked in the tests'
/// Italian default, and both languages through `BilingualText`.
@Suite(.serialized) @MainActor struct RecordingRowAccessibilityTests {
    private struct Node {
        let role: String
        let label: String
    }

    private func recording() -> RecmanRecording {
        RecmanRecording(id: "a", courseCode: "058167", academicYear: 2026, title: "Lesson A",
                        recordedAt: Date(timeIntervalSince1970: 1_791_504_000), kind: "Lezione",
                        duration: "90 min", size: nil, previewURL: URL(string: "https://onlineservices.polimi.it/")!)
    }

    /// Walks the tree through `AnyObject` dispatch: SwiftUI's elements are private classes that
    /// answer the NSAccessibility methods without being typed as conforming to the protocol.
    private func collect(_ element: Any, depth: Int = 0, into nodes: inout [Node]) {
        guard depth < 30 else { return }
        let object = element as AnyObject
        if object.isAccessibilityElement?() == true {
            let role: NSAccessibility.Role? = object.accessibilityRole?() ?? nil
            let label: String? = object.accessibilityLabel?() ?? nil
            nodes.append(Node(role: role?.rawValue ?? "", label: label ?? ""))
        }
        let children: [Any] = (object.accessibilityChildren?() ?? nil) ?? []
        for child in children { collect(child, depth: depth + 1, into: &nodes) }
    }

    /// The accessibility elements of one hosted row, polled until SwiftUI has published the
    /// row's buttons (an observable fact, not a fixed wait), at most 10 s.
    private func elements(isNew: Bool, isWatchlisted: Bool) async throws -> [Node] {
        let row = RecordingRow(recording: recording(), number: 1, isNew: isNew, isOpening: false, isWatchlisted: isWatchlisted,
                               canEdit: true, canPlay: true, watchlistCourseName: "Analisi", watch: .unknown,
                               actions: .init(toggleWatchlist: {}, play: {}, setDone: { _ in }))
        let host = NSHostingView(rootView: row.frame(width: 640))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        let deadline = Date().addingTimeInterval(10)
        var nodes: [Node] = []
        repeat {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            nodes = []
            collect(window, into: &nodes)
        } while !nodes.contains(where: { $0.label.hasPrefix("Riproduci") }) && Date() < deadline
        return nodes
    }

    /// Turns the app's assistive-client switch on or off (see the suite's comment).
    private func setAssistiveClient(_ on: Bool) {
        NSApplication.shared.perform(Selector(("accessibilitySetValue:forAttribute:")), with: NSNumber(value: on), with: "AXEnhancedUserInterface")
    }

    /// A row that isn't new exposes no unnamed element: the clear dot is hidden from VoiceOver,
    /// so it no longer stops on an empty element at the start of most rows. A new row still
    /// announces "Nuova". Mutation: put back `.accessibilityLabel(isNew ? … : "")` without
    /// `.accessibilityHidden(!isNew)` and the old row gains an unlabelled element; hide the dot
    /// always and the new row loses "Nuova".
    @Test(.timeLimit(.minutes(1))) func onlyNewRowsExposeTheDot() async throws {
        setAssistiveClient(true)
        defer { setAssistiveClient(false) }
        do {
            let old = try await elements(isNew: false, isWatchlisted: false)
            #expect(old.contains { $0.label == "Riproduci Lesson A" }, "the tree was read: \(old)")
            let unnamed = old.filter { $0.label.isEmpty && $0.role != NSAccessibility.Role.staticText.rawValue && $0.role != NSAccessibility.Role.group.rawValue && $0.role != NSAccessibility.Role.window.rawValue }
            #expect(unnamed.isEmpty, "unnamed elements in a row that isn't new: \(unnamed)")
            #expect(!old.contains { $0.label == "Nuova" })

            let new = try await elements(isNew: true, isWatchlisted: false)
            #expect(new.contains { $0.label == "Nuova" }, "a new row announces it: \(new)")
        }
    }

    /// The bookmark button names the lecture it acts on, in both states and both languages.
    /// Mutation: go back to the bare "Aggiungi alla watchlist" label and both checks fail.
    @Test(.timeLimit(.minutes(1))) func bookmarkButtonNamesTheLecture() async throws {
        #expect(RecordingRow.watchlistAccessibilityLabel(isWatchlisted: false, title: "Lesson A")
                == BilingualText("Aggiungi Lesson A alla watchlist", "Add Lesson A to watchlist"))
        #expect(RecordingRow.watchlistAccessibilityLabel(isWatchlisted: true, title: "Lesson A")
                == BilingualText("Rimuovi Lesson A dalla watchlist", "Remove Lesson A from watchlist"))
        setAssistiveClient(true)
        defer { setAssistiveClient(false) }
        do {
            let add = try await elements(isNew: false, isWatchlisted: false)
            #expect(add.contains { $0.role == NSAccessibility.Role.button.rawValue && $0.label == "Aggiungi Lesson A alla watchlist" }, "\(add)")
            let remove = try await elements(isNew: false, isWatchlisted: true)
            #expect(remove.contains { $0.role == NSAccessibility.Role.button.rawValue && $0.label == "Rimuovi Lesson A dalla watchlist" }, "\(remove)")
        }
    }
}
