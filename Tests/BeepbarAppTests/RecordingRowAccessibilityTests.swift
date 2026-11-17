import AppKit
import SwiftUI
import Testing
import BeepbarCore
@testable import BeepbarApp

/// Keeps SwiftUI's process-wide accessibility tree enabled across overlapping async tests.
@MainActor enum AssistiveClient {
    private static var users = 0

    static func acquire() {
        if users == 0 { setEnabled(true) }
        users += 1
    }

    static func release() {
        precondition(users > 0)
        users -= 1
        if users == 0 { setEnabled(false) }
    }

    private static func setEnabled(_ enabled: Bool) {
        NSApplication.shared.perform(Selector(("accessibilitySetValue:forAttribute:")), with: NSNumber(value: enabled), with: "AXEnhancedUserInterface")
    }
}

/// What VoiceOver finds in a Recordings row, read from the real accessibility tree of a hosted
/// `RecordingRow` (#196). SwiftUI builds that tree only for an assistive client, so the test turns
/// on `AXEnhancedUserInterface` for the app (the switch VoiceOver flips) while it runs and off
/// again afterwards, shared with other tests using the process-global switch. Text is checked in the tests'
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
    private func elements(isNew: Bool, isWatchlisted: Bool, recording lesson: RecmanRecording? = nil) async throws -> [Node] {
        let row = RecordingRow(recording: lesson ?? recording(), number: 1, isNew: isNew, isOpening: false, isWatchlisted: isWatchlisted,
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

    /// A row that isn't new exposes no unnamed element: the clear dot is hidden from VoiceOver,
    /// so it no longer stops on an empty element at the start of most rows. A new row still
    /// announces "Nuova". Mutation: put back `.accessibilityLabel(isNew ? … : "")` without
    /// `.accessibilityHidden(!isNew)` and the old row gains an unlabelled element; hide the dot
    /// always and the new row loses "Nuova".
    @Test(.timeLimit(.minutes(1))) func onlyNewRowsExposeTheDot() async throws {
        AssistiveClient.acquire()
        defer { AssistiveClient.release() }
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
        AssistiveClient.acquire()
        defer { AssistiveClient.release() }
        do {
            let add = try await elements(isNew: false, isWatchlisted: false)
            #expect(add.contains { $0.role == NSAccessibility.Role.button.rawValue && $0.label == "Aggiungi Lesson A alla watchlist" }, "\(add)")
            let remove = try await elements(isNew: false, isWatchlisted: true)
            #expect(remove.contains { $0.role == NSAccessibility.Role.button.rawValue && $0.label == "Rimuovi Lesson A dalla watchlist" }, "\(remove)")
        }
    }

    /// A linked lesson's bookmark is a plain image with its explanation, not a button, so a click
    /// or a VoiceOver press can never delete; every row has the "⋯" menu (#286). Mutation: draw
    /// the pinned slot as a `Button` and the first check fails; drop `moreMenu` and the second does.
    @Test(.timeLimit(.minutes(1))) func linkedLessonBookmarkIsInertAndRowsHaveAMenu() async throws {
        AssistiveClient.acquire()
        defer { AssistiveClient.release() }
        let manual = ManualWebexLesson(title: "Guest", courseName: "", link: URL(string: "https://politecnicomilano.webex.com/ldr.php?RCID=a11y")!, addedAt: .now).recording
        let nodes = try await elements(isNew: false, isWatchlisted: true, recording: manual)
        let pinned = RecordingRow.pinnedBookmarkHelp.italian
        #expect(nodes.contains { $0.label == pinned }, "the explanation is exposed: \(nodes)")
        #expect(!nodes.contains { $0.role == NSAccessibility.Role.button.rawValue && $0.label == pinned }, "the pinned bookmark is a button: \(nodes)")
        #expect(!nodes.contains { $0.role == NSAccessibility.Role.button.rawValue && ($0.label.hasPrefix("Rimuovi") || $0.label.hasPrefix("Elimina")) })
        // The menu button's name is the system's ("More") whatever label SwiftUI is given, so the
        // test checks that the element exists, on a linked and on an archive row.
        #expect(nodes.contains { $0.role == NSAccessibility.Role.menuButton.rawValue }, "the ⋯ menu: \(nodes)")
        let archive = try await elements(isNew: false, isWatchlisted: false)
        #expect(archive.contains { $0.role == NSAccessibility.Role.menuButton.rawValue }, "\(archive)")
    }
}
