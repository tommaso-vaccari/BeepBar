import AppKit
import SwiftUI
import Testing
import BeepbarCore
@testable import BeepbarApp

/// Exercises the real Activity hierarchy after Show more has revealed a whole large course.
/// Replacing the inner LazyVStack with VStack must fail the construction bound (#99).
@MainActor @Suite(.serialized) struct ActivityVirtualizationTests {
    @Test(.timeLimit(.minutes(1))) func revealedRowsStayLazyAndTheLastRowIsReachable() async throws {
        let scenario = try UIFixtureScenario(arguments: ["--scenario", "activity-15000", "--report", "/tmp/activity-unused-\(UUID().uuidString).json"])
        let fixture = try await UIFixture.make(scenario)
        var constructed = Set<String>()
        ActivityPageProbes.row = { constructed.insert($0) }
        let host = NSHostingView(rootView: ActivityPage(authentication: fixture.controller)
            .environment(\.uiFixtureExpandedActivity, true)
            .environment(\.uiFixtureActivityVisibleRows, 15_000))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 0
        window.orderFront(nil)
        defer { ActivityPageProbes.row = nil; window.close(); fixture.dispose() }
        func settle(until condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            } while !condition() && Date() < deadline
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await settle { constructed.contains("1/file/fixture-0") }
        #expect(constructed.contains("1/file/fixture-0"))
        #expect(constructed.count < 200, "constructed \(constructed.count) rows before scrolling")
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        let scroll = try #require(scrollViews(host).first)
        let document = try #require(scroll.documentView)
        document.scroll(NSPoint(x: 0, y: document.bounds.maxY))
        try await settle { constructed.contains("1/file/fixture-14999") }
        #expect(constructed.contains("1/file/fixture-14999"), "last revealed row was unreachable")
        #expect(constructed.count < 400, "scrolling to the end constructed \(constructed.count) rows")
    }

    @MainActor private final class Opener: ActivityFileOpening {
        var opened: [URL] = []
        var revealed: [URL] = []
        func open(_ url: URL) { opened.append(url) }
        func reveal(_ url: URL) { revealed.append(url) }
    }

    private func button(in element: Any, label: String, depth: Int = 0) -> AnyObject? {
        guard depth < 40 else { return nil }
        let object = element as AnyObject
        let role: NSAccessibility.Role? = object.accessibilityRole?() ?? nil
        let title: String = (object.accessibilityLabel?() ?? nil) ?? ""
        if (role == .button || role == .link) && title.contains(label) { return object }
        let children: [Any] = (object.accessibilityChildren?() ?? nil) ?? []
        for child in children {
            if let found = button(in: child, label: label, depth: depth + 1) { return found }
        }
        return nil
    }

    @Test(.timeLimit(.minutes(2)), arguments: [1_000, 15_000])
    func firstAndLastVisibleRowsKeepTheirAccessibleActions(count: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ActivityViewportTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try SyncDatabase(url: root.appending(path: "state.sqlite"))
        let rootID = UUID()
        try await database.registerRoot(id: rootID, canonicalPath: root.path)
        let opener = Opener()
        let controller = WeBeepAuthenticationController(testRootURL: root, database: database, rootID: rootID,
            fileOpener: opener, credentialVault: CredentialVault(read: { _ in "synthetic" }, write: { _ in }))
        let firstName = "Synthetic slides 0.pdf"
        let lastName = "Synthetic script \(count - 1).py"
        let items = (0..<count).map { index in
            SyncedItem(id: "fixture-\(index)", name: index == count - 1 ? lastName : "Synthetic slides \(index).pdf", kind: .added)
        }
        let course = CourseSyncCount(courseID: 1, courseFolder: "Synthetic course", added: count, updated: 0, items: items)
        controller.setSyncStateForTesting(.synced(SyncCompletionSummary(completedAt: Date(timeIntervalSince1970: 1_791_504_000),
            added: count, updated: 0, unchanged: 0, preservedLocal: 0, conflicts: 0, failures: 0, perCourse: [course])))
        for (index, name) in [(0, firstName), (count - 1, lastName)] {
            let relative = "Synthetic course/\(name)"
            let url = root.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic".utf8).write(to: url)
            try await database.upsertBaseline(rootID: rootID, baseline: Baseline(remoteID: "fixture-\(index)",
                relativePath: try RelativePath(relative), sha256: "synthetic", remoteRevision: "1"))
        }
        NSApplication.shared.perform(Selector(("accessibilitySetValue:forAttribute:")), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
        defer { NSApplication.shared.perform(Selector(("accessibilitySetValue:forAttribute:")), with: NSNumber(value: false), with: "AXEnhancedUserInterface") }
        let host = NSHostingView(rootView: ActivityPage(authentication: controller))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func settle(until condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            repeat {
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            } while !condition() && Date() < deadline
            #expect(condition(), "Activity UI did not reach the expected state")
        }
        try await settle { button(in: window, label: "Synthetic course") != nil }
        let disclosure = try #require(button(in: window, label: "Synthetic course"))
        #expect(disclosure.accessibilityPerformPress?() == true)
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        let scroll = try #require(scrollViews(host).first)
        let document = try #require(scroll.documentView)
        func isVisible(_ object: AnyObject) -> Bool {
            let frame: NSRect = object.accessibilityFrame?() ?? .zero
            let viewport = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
            return !frame.isEmpty && viewport.intersects(frame)
        }
        func visibleButton(_ label: String) -> AnyObject? {
            guard let found = button(in: window, label: label), isVisible(found) else { return nil }
            return found
        }
        try await settle { visibleButton(firstName) != nil }
        let first = try #require(visibleButton(firstName))
        #expect(first.accessibilityHelp?() == ActivityClickAction.open.accessibilityHint)
        #expect(first.accessibilityPerformPress?() == true)
        try await settle { opener.opened.count == 1 }
        #expect(opener.opened.map(\.lastPathComponent) == [firstName])
        #expect(opener.revealed.isEmpty)
        var visible = ActivityRowLayout.pageSize
        var reveals = 0
        while visible < count {
            let title = try #require(ActivityRowLayout.showMoreTitle(for: ActivityRowLayout.page(for: course, visible: visible)))
            func bottom() {
                document.scroll(NSPoint(x: 0, y: document.bounds.maxY))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            try await settle { bottom(); return visibleButton(title) != nil }
            let more = try #require(visibleButton(title))
            #expect(more.accessibilityPerformPress?() == true)
            visible = ActivityRowLayout.nextVisibleCount(after: visible, total: count)
            reveals += 1
        }
        #expect(reveals == (count == 1_000 ? 3 : 7))
        try await settle {
            document.scroll(NSPoint(x: 0, y: document.bounds.maxY))
            scroll.reflectScrolledClipView(scroll.contentView)
            return visibleButton(lastName) != nil
        }
        let last = try #require(visibleButton(lastName))
        #expect(last.accessibilityHelp?() == ActivityClickAction.showInFinder.accessibilityHint)
        #expect(last.accessibilityPerformPress?() == true)
        try await settle { opener.revealed.count == 1 }
        #expect(opener.revealed.map(\.lastPathComponent) == [lastName])
        #expect(opener.opened.map(\.lastPathComponent) == [firstName])
        #expect(controller.activityItemProblems.isEmpty)
    }

}
