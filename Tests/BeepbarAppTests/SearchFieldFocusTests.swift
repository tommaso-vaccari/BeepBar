import AppKit
import Foundation
import Testing
import BeepbarCore
@testable import BeepbarApp

/// The Corsi search field let go of the cursor only when another text field took it: it was
/// focused as soon as the window opened, and no click on a row, a switch or the background, nor
/// Esc, could take the focus away. These tests host the real shell in the real configuration
/// window and send it the same mouse and keyboard events AppKit delivers, then look at what
/// actually holds the focus. The window stays invisible and the app is never activated, so they
/// run in CI and leave the desktop alone.
@MainActor @Suite(.serialized) struct SearchFieldFocusTests {
    /// Opening the window used to put the cursor in "Cerca corsi" on every open, since AppKit
    /// focuses the first text field it finds. Guards `initialFirstResponder`.
    @Test func openingTheWindowFocusesNothing() throws {
        let page = try OpenPage()
        defer { page.close() }
        #expect(!page.searchIsFocused)
        #expect(page.searchField.placeholderString == "Cerca corsi")
    }

    /// Clicking a course row (not a control on it) takes the cursor out of the field and changes
    /// nothing else. Guards the click-out in `ConfigurationWindow.sendEvent`.
    @Test func clickingACourseRowLetsGoOfTheField() throws {
        let page = try OpenPage()
        defer { page.close() }
        page.clickSearchField()
        #expect(page.searchIsFocused, "precondition: a click on the field focuses it")
        page.click(page.rowTextPoint)
        #expect(!page.searchIsFocused)
        #expect(page.authentication.enabledCourseIDs == [1])
    }

    /// A switch is an AppKit control that never takes the focus itself, so clicking it left the
    /// field focused. Now the field lets go and the click still reaches the switch: ending editing
    /// must not swallow the click.
    @Test func clickingASwitchLetsGoOfTheFieldAndStillToggles() throws {
        let page = try OpenPage()
        defer { page.close() }
        page.clickSearchField()
        #expect(page.searchIsFocused, "precondition: a click on the field focuses it")
        page.click(try page.firstSwitchPoint())
        #expect(!page.searchIsFocused)
        #expect(page.authentication.enabledCourseIDs.isEmpty, "the click must still turn course 1 off")
    }

    /// The empty part of the header and the page background hold nothing focusable either.
    @Test func clickingTheBackgroundLetsGoOfTheField() throws {
        let page = try OpenPage()
        defer { page.close() }
        page.clickSearchField()
        page.click(page.headerBlankPoint)
        #expect(!page.searchIsFocused)
        page.clickSearchField()
        page.click(page.bottomPaddingPoint)
        #expect(!page.searchIsFocused)
    }

    /// Clicking inside the field while typing must keep the cursor there: the click lands on the
    /// field editor, which is text, not on the background.
    @Test func clickingInsideTheFieldKeepsTyping() throws {
        let page = try OpenPage()
        defer { page.close() }
        page.clickSearchField()
        page.press("a", keyCode: 0)
        page.clickSearchField()
        #expect(page.searchIsFocused)
        #expect(page.searchField.stringValue == "a")
    }

    /// Esc first clears the query and keeps the cursor, so a new search can be typed at once; a
    /// second Esc lets go of the field. Before, Esc did neither.
    @Test func escapeClearsTheQueryThenLetsGo() throws {
        let page = try OpenPage()
        defer { page.close() }
        page.clickSearchField()
        page.press("c", keyCode: 8)
        #expect(page.searchField.stringValue == "c", "precondition: typing reaches the field")
        page.press("\u{1b}", keyCode: 53)
        #expect(page.searchField.stringValue.isEmpty)
        #expect(page.searchIsFocused)
        page.press("\u{1b}", keyCode: 53)
        #expect(!page.searchIsFocused)
    }

    /// The decision on its own, including the cases the page doesn't reach: with no editing going
    /// on a click changes nothing, and a click on another text field is left to AppKit, which
    /// moves the cursor there (the rename field, for example).
    @Test func whichClicksEndEditing() {
        let editor = NSTextView()
        editor.isFieldEditor = true
        #expect(ConfigurationWindow.clickEndsTextEditing(firstResponder: editor, clickedView: NSView()))
        #expect(ConfigurationWindow.clickEndsTextEditing(firstResponder: editor, clickedView: nil))
        #expect(!ConfigurationWindow.clickEndsTextEditing(firstResponder: editor, clickedView: editor))
        #expect(!ConfigurationWindow.clickEndsTextEditing(firstResponder: editor, clickedView: NSTextField()))
        #expect(!ConfigurationWindow.clickEndsTextEditing(firstResponder: NSView(), clickedView: NSView()))
        #expect(!ConfigurationWindow.clickEndsTextEditing(firstResponder: NSTextView(), clickedView: NSView()), "a text view that isn't the field editor isn't a field being typed in")
        #expect(!ConfigurationWindow.clickEndsTextEditing(firstResponder: nil, clickedView: NSView()))
    }
}

/// The Corsi page in an invisible configuration window built by `makeWindow`, as `show` builds it.
@MainActor private final class OpenPage {
    let authentication: WeBeepAuthenticationController
    let window: ConfigurationWindow
    let searchField: NSTextField
    private let root: URL

    init() throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        authentication = WeBeepAuthenticationController(testRootURL: root)
        // More than six courses, so Corsi shows the search field. Course 1 starts selected (the
        // test controller's default) and is listed first.
        authentication.setCoursesForTesting((1...12).map { index in
            RemoteCourseSummary(id: Int64(index), shortName: "\(index)", displayName: "Corso \(index)", isVisible: true, startDate: nil, endDate: nil)
        })
        window = ConfigurationWindowController.makeWindow(authentication: authentication, router: ShellRouter())
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        let content = try #require(window.contentView)
        var found: NSTextField?
        Self.settle { found = Self.find(in: content) { ($0 as? NSTextField)?.isEditable == true } as? NSTextField; return found != nil }
        searchField = try #require(found, "Corsi must show the search field with more than six courses")
        Self.settle(for: 0.2)
    }

    func close() {
        window.close()
        Self.settle(for: 0.1)
        try? FileManager.default.removeItem(at: root)
    }

    var searchIsFocused: Bool {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return editor.delegate as? NSTextField === searchField
    }

    private var contentBounds: NSRect { window.contentView?.bounds ?? .zero }

    /// The folder name of a row in the middle of the list: plain text, no control.
    var rowTextPoint: NSPoint {
        let field = searchField.convert(searchField.bounds, to: nil)
        return NSPoint(x: 140, y: field.minY - 160)
    }

    /// The empty space between "Corsi" and the search field.
    var headerBlankPoint: NSPoint {
        let field = searchField.convert(searchField.bounds, to: nil)
        return NSPoint(x: field.minX - 60, y: field.midY)
    }

    /// The page padding below the course list.
    var bottomPaddingPoint: NSPoint { NSPoint(x: contentBounds.midX, y: 6) }

    func firstSwitchPoint() throws -> NSPoint {
        let content = try #require(window.contentView)
        let switches = Self.findAll(in: content) { String(describing: type(of: $0)).contains("Switch") }
            .map { $0.convert($0.bounds, to: nil) }
        // The highest one on screen is the first row's, course 1.
        let top = try #require(switches.max { $0.midY < $1.midY }, "the course rows must have switches")
        return NSPoint(x: top.midX, y: top.midY)
    }

    func clickSearchField() {
        let frame = searchField.convert(searchField.bounds, to: nil)
        click(NSPoint(x: frame.midX, y: frame.midY))
    }

    func click(_ point: NSPoint) {
        for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
            Self.settle(for: 0.05)
        }
        Self.settle(for: 0.2)
    }

    func press(_ characters: String, keyCode: UInt16) {
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
            window.sendEvent(event)
            Self.settle(for: 0.05)
        }
        Self.settle(for: 0.2)
    }

    /// Runs the main run loop, where SwiftUI lays out and applies focus changes, until `done`
    /// holds or ten seconds pass (a slow CI machine gets time, a broken page doesn't hang).
    static func settle(until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    static func settle(for seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func find(in view: NSView, _ match: (NSView) -> Bool) -> NSView? {
        findAll(in: view, match).first
    }

    static func findAll(in view: NSView, _ match: (NSView) -> Bool) -> [NSView] {
        (match(view) ? [view] : []) + view.subviews.flatMap { findAll(in: $0, match) }
    }
}
