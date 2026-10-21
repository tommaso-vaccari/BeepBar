import AppKit
import SwiftUI
import Testing
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
}
