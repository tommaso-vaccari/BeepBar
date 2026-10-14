import AppKit
import BeepbarCore
import SwiftUI
import UserNotifications
import os

enum BeepbarLog {
    static let lifecycle = Logger(subsystem: "io.github.tvaccari.beepbar", category: "lifecycle")
    static let scheduler = Logger(subsystem: "io.github.tvaccari.beepbar", category: "scheduler")
    static let sync = Logger(subsystem: "io.github.tvaccari.beepbar", category: "sync")
}

#if !UI_PERFORMANCE_HARNESS
@main
struct BeepbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No window-bearing scene: the status item and its menu are owned and driven
        // entirely by AppKit (see StatusItemController) to avoid the SwiftUI MenuBarExtra
        // Button→AppKit bridging path that crashed with SIGBUS in ButtonAction.callAsFunction()
        // when @Published state mutated during menu tracking (issue #30). `Settings` is the
        // lightest scene that satisfies `App`'s requirement without creating any UI on launch.
        Settings { EmptyView() }
    }
}

#endif

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    // Owned here, not by the SwiftUI App struct: for a window-less scene, SwiftUI doesn't
    // guarantee `body` runs before applicationDidFinishLaunching, so a reference handed over
    // from `body` can still be nil when this fires. AppKit does guarantee the delegate itself
    // is fully constructed and assigned before that call, so creating the controller here
    // removes the race entirely.
    let authentication = WeBeepAuthenticationController()
    private var statusItemController: StatusItemController?
    /// Kept here because `UNUserNotificationCenter.delegate` is weak.
    private lazy var notificationResponder = NotificationResponder { [weak self] destination in
        guard let self else { return }
        ConfigurationWindowController.shared.show(self.authentication, page: ShellPage(destination))
    }

    /// Set before launch finishes so a click on a notification that launched BeepBar is delivered.
    /// Not in a UI preview, which must not touch the installed app's notifications.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !PreviewMode.isActive else { return }
        UNUserNotificationCenter.current().delegate = notificationResponder
    }
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        BeepbarLog.lifecycle.notice("Application launched version=\(version, privacy: .public) build=\(build, privacy: .public)")
        _ = UpdaterController.shared
        // Once per install: on by default, never re-applied after the user turns it off.
        // Telemetry starts after it, so the day's first signal reports the login item's real state.
        Task { [authentication] in
            await LaunchAtLoginController.shared.applyDefaultOnLaunch()
            await DailyTelemetryController.shared.startForApplication(context: {
                DailyTelemetryContext(
                    language: .current,
                    systemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                    automaticSyncEnabled: authentication.automaticSyncEnabled,
                    automaticSyncInterval: authentication.automaticSyncInterval,
                    dataSaverEnabled: authentication.dataSaverEnabled,
                    recordingsEnabled: authentication.recordingsEnabledWithoutCreating,
                    launchAtLogin: LaunchAtLoginController.shared.status.map(LaunchAtLoginPolicy.isOn))
            })
        }
        statusItemController = StatusItemController(authentication: authentication)
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-preview") {
            ConfigurationWindowController.shared.show(authentication, page: ProcessInfo.processInfo.arguments.contains("--watchlist-preview") ? .recordings : .home)
            return
        }
#endif
        guard authentication.needsOnboarding else { return }
        ConfigurationWindowController.shared.show(authentication)
    }

    /// Two ways in. A quit from outside (Sparkle's installer, logout, the Dock, `osascript`) arrives
    /// here first and may wait for a sync with `.terminateLater`: AppKit keeps running main-actor
    /// work during that wait. "Esci" arrives here only after `prepareForMenuQuit()` has already
    /// wound everything down, and must get `.terminateNow`: `.terminateLater` on that path hangs
    /// BeepBar for good (see `prepareForMenuQuit()` and `scripts/quit-probe`). The answer comes
    /// from `terminationReply`, which pins that rule.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let menuQuitDrained = authentication.menuQuitDrained
        let pendingSync = menuQuitDrained ? nil : authentication.prepareForTermination()
        let reply = WeBeepAuthenticationController.terminationReply(menuQuitDrained: menuQuitDrained, hasPendingSync: pendingSync != nil)
        guard reply == .terminateLater, let syncTask = pendingSync else {
            BeepbarLog.lifecycle.notice("Termination accepted immediately menuQuit=\(menuQuitDrained, privacy: .public)")
            return .terminateNow
        }
        guard !terminationPending else { return .terminateLater }
        BeepbarLog.lifecycle.notice("Termination waiting for active synchronization")
        terminationPending = true
        Task { [weak self] in
            await syncTask.value
            self?.finishTermination()
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.finishTermination()
        }
        return .terminateLater
    }

    private func finishTermination() {
        guard terminationPending else { return }
        terminationPending = false
        BeepbarLog.lifecycle.notice("Termination accepted after synchronization shutdown")
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}

/// Hand-built NSStatusItem/NSMenu replacement for the old SwiftUI `MenuBarExtra`.
/// Menu items are discarded and rebuilt from scratch in `menuNeedsUpdate(_:)` right before
/// each time the menu opens, instead of being bound to `@Published` state via SwiftUI.
///
/// Deliberately NOT `@MainActor`, and deliberately never calls into any `@MainActor`-isolated
/// member of `authentication` synchronously. AppKit invokes `NSMenuDelegate`/target-action
/// methods via Objective-C dispatch, and bridging that into `@MainActor`-isolated Swift code
/// (whether through a compiler-synthesized `@objc` thunk or an explicit `MainActor.assumeIsolated`)
/// makes the Swift runtime dynamically re-verify "is this actually the main executor?"
/// (`swift_task_isCurrentExecutorWithFlagsImpl` → `swift_getObjectType`). On this OS build that
/// verification itself crashes with SIGBUS at a fixed address inside `libswiftCore.dylib` — the
/// same instruction, same address, in five separate app builds, both before and after #31's
/// MenuBarExtra→NSStatusItem rewrite (`ButtonAction.callAsFunction()` pre-#31,
/// `menuNeedsUpdate(_:)` post-#31), always on the first status-item interaction after the Mac
/// wakes from sleep. #31 relocated which `@objc` call site triggered the check; it didn't remove
/// the check, so the crash reappeared. The delegate requirement itself is `@MainActor` in the
/// AppKit SDK, so its implementation must be explicitly `nonisolated`; otherwise its generated
/// Objective-C thunk performs the crashing check before the method body can read the snapshot.
/// The method reads only `authentication`'s `nonisolated(unsafe) menuBarSnapshot` — see its doc
/// comment — and the action methods hand off to the main actor via `Task`.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let authentication: WeBeepAuthenticationController

    @MainActor init(authentication: WeBeepAuthenticationController) {
        self.authentication = authentication
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        Self.setSymbol(authentication.menuBarSymbol, on: statusItem)
        // Updates arrive from the main actor (see `onMenuBarSymbolChange`), never from an AppKit
        // callback into this class.
        authentication.onMenuBarSymbolChange = { [statusItem] symbol in Self.setSymbol(symbol, on: statusItem) }
#if !UI_PERFORMANCE_HARNESS
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
#endif
        PerformanceTrace.shared.event("ui.iconReady", category: .ui)
    }

    @MainActor private static func setSymbol(_ symbol: String, on statusItem: NSStatusItem) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "BeepBar")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        // Budget: 1 ms (AGENTS.md, Performance). The interval shows the build in Instruments.
        let trace = PerformanceTrace.shared.begin("ui.menuNeedsUpdate", category: .ui)
        defer { PerformanceTrace.shared.end("ui.menuNeedsUpdate", category: .ui, state: trace) }
        Self.build(from: authentication.menuBarSnapshot, into: menu, target: self)
    }

    /// The whole menu, from `snapshot` alone, replacing what `menu` held: status, detail, action,
    /// Open, separator, Quit. `nonisolated` and
    /// static for the same reason as `menuNeedsUpdate` (it runs inside that AppKit callback and
    /// must not touch main-actor state), and so tests can check the item order without a status
    /// item; `target` is nil there. The three actions keep their `Task { @MainActor in … }` hops.
    nonisolated static func build(from snapshot: MenuBarSnapshot, into menu: NSMenu, target: StatusItemController?) {
        menu.removeAllItems()

        let titleItem = NSMenuItem()
        titleItem.title = snapshot.title
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        let detailItem = NSMenuItem()
        detailItem.attributedTitle = NSAttributedString(
            string: snapshot.detail,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.secondaryLabelColor]
        )
        detailItem.isEnabled = false
        menu.addItem(detailItem)

        let actionItem = NSMenuItem(title: snapshot.actionTitle, action: #selector(performAction), keyEquivalent: "")
        actionItem.target = target
        menu.addItem(actionItem)

        // Open sits right under the action (Sync now), not at the end of the menu.
        let openItem = NSMenuItem(title: snapshot.openTitle, action: #selector(openConfiguration), keyEquivalent: "")
        openItem.target = target
        menu.addItem(openItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: snapshot.quitTitle, action: #selector(quit), keyEquivalent: "")
        quitItem.target = target
        menu.addItem(quitItem)
    }

    /// Not called by `build` since issue #164: the icon popup shows no recordings section.
    /// Kept, with its tests, because the issue discussion proposes bringing the section back
    /// behind a Settings option; remove it together with `recordingLines` if that is dropped.
    ///
    /// The recordings section: nothing when `snapshot.recordingLines` is empty, otherwise a
    /// separator, the "Registrazioni" section header (`NSMenuItem.sectionHeader`, macOS 14, the
    /// deployment target) and one line per course. It reads the snapshot it is given and nothing
    /// else.
    /// - A line is clickable only when it has a target, which `recordingMenuLines` gives only with
    ///   a known account (owner) and a known next lecture that passes `validatedNext`. It gets
    ///   `target` (this `StatusItemController`, never `NSApp` or the account controller),
    ///   `playRecording(_:)`, the `RecordingMenuTarget` as `representedObject`, and the
    ///   "Riproduci: «…»" tooltip. Its only path to the main actor is that action's
    ///   `Task { @MainActor in … }` hop (issue #30).
    /// - A line without one (all done, no known or valid next, no account) stays grey:
    ///   disabled, no target, no action.
    /// Enabling relies on NSMenu's autoenabling (an item whose target answers its action is
    /// enabled, one without an action is not). `validateMenuItem(_:)` is deliberately not
    /// implemented: its protocol is `@MainActor`, a new AppKit-to-main-actor crossing.
    nonisolated static func addRecordingItems(from snapshot: MenuBarSnapshot, to menu: NSMenu, target: StatusItemController?) {
        guard !snapshot.recordingLines.isEmpty else { return }
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: snapshot.recordingsTitle))
        for line in snapshot.recordingLines {
            let item = NSMenuItem()
            item.title = line.title
            if let payload = line.target {
                item.target = target
                item.action = #selector(playRecording(_:))
                item.representedObject = payload
                item.toolTip = line.toolTip
            } else {
                item.isEnabled = false
            }
            menu.addItem(item)
        }
    }

    /// A click on a recordings line. `nonisolated` on purpose and kept minimal (a log line and the
    /// dispatch): it reads only the clicked item's `representedObject` (a plain `Sendable`
    /// value), no main-actor state, not even `menuBarSnapshot`, and hands it to
    /// `dispatchRecordingClick`, which hops. Never
    /// mark it `@MainActor` or point the item at a `@MainActor` method: AppKit's Objective-C call
    /// would then make the Swift runtime verify the executor, the check that crashed with SIGBUS
    /// after wake (issues #30, #31). `RecordingsMenuBarTests` calls it from a nonisolated
    /// context, so marking it `@MainActor` no longer compiles.
    @objc nonisolated func playRecording(_ sender: NSMenuItem) {
        BeepbarLog.lifecycle.notice("Menu recording line selected")
        Self.dispatchRecordingClick(sender.representedObject, to: authentication)
    }

    /// Hands a recordings click to the main actor: anything but a `RecordingMenuTarget` (or
    /// nothing) is ignored; the target is played by `playNextRecording` inside the
    /// `Task { @MainActor in … }` hop, the issue #30 fix, like the other actions. Reads no
    /// main-actor state. To change what a click does, change what runs inside the hop, never
    /// the hop itself (no `DispatchQueue.main.async`, `MainActor.assumeIsolated`,
    /// `RunLoop.main.perform`). Static so tests can prove the hop by behaviour without a status
    /// item.
    nonisolated static func dispatchRecordingClick(_ payload: Any?, to authentication: WeBeepAuthenticationController) {
        guard let target = payload as? RecordingMenuTarget else { return }
        Task { @MainActor in authentication.playNextRecording(target) }
    }

    @objc private func performAction() {
        BeepbarLog.lifecycle.notice("Menu primary action selected")
        let authentication = authentication
        Task { @MainActor in authentication.performMenuBarAction() }
    }

    @objc private func openConfiguration() {
        BeepbarLog.lifecycle.notice("Menu open selected")
        let authentication = authentication
        Task { @MainActor in ConfigurationWindowController.shared.show(authentication) }
    }

    /// "Esci". The `Task { @MainActor in … }` hop is the issue #30 fix: keep it exactly as it is.
    /// Inside it, the shutdown work comes first and `terminate` last, with nothing left pending.
    /// A bare `NSApp.terminate(nil)` here, while a sync is still winding down, hangs BeepBar for
    /// good (see `prepareForMenuQuit()`), and swapping the hop for `DispatchQueue.main.async`
    /// hangs the same way. Rerun `scripts/quit-probe` after touching anything on this path.
    @objc private func quit() {
        BeepbarLog.lifecycle.notice("Menu quit selected")
        let authentication = authentication
        Task { @MainActor in
            guard await authentication.prepareForMenuQuit() else { return }
            NSApp.terminate(nil)
        }
    }
}

@MainActor final class ConfigurationWindowController: NSObject, NSWindowDelegate {
    static let shared = ConfigurationWindowController()
    private var window: NSWindow?
    private var appearanceTrace: OSSignpostIntervalState?
    private let router = ShellRouter()
    /// The controller the window shows, to tell Recordings when the window is gone.
    private weak var authentication: WeBeepAuthenticationController?
    private static let frameAutosaveName = "BeepbarConfigurationWindow"

    func show(_ authentication: WeBeepAuthenticationController, page: ShellPage? = nil) {
        BeepbarLog.lifecycle.notice("Configuration window requested")
        self.authentication = authentication
        if window?.isKeyWindow != true {
            if let appearanceTrace {
                PerformanceTrace.shared.end("ui.configurationWindow", category: .ui, state: appearanceTrace)
            }
            appearanceTrace = PerformanceTrace.shared.begin("ui.configurationWindow", category: .ui)
        }
        // Onboarding ignores the page (it shows onboarding anyway), and keeping it would land the user
        // on, say, Conflitti once onboarding ends instead of Corsi.
        if let page, !authentication.needsOnboarding { router.page = page }
        // Activate before ordering the window in: with macOS 14+ cooperative activation the
        // deprecated `activate(ignoringOtherApps:)` is ignored, which left the window open but
        // inactive, so the first click only activated the app and seemed to do nothing.
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            let window = Self.makeWindow(authentication: authentication, router: router)
            window.delegate = self
            // The window object is rebuilt on every open (see windowWillClose), so let AppKit
            // remember where the user left it.
            if !window.setFrameUsingName(Self.frameAutosaveName) { window.center() }
            window.setFrameAutosaveName(Self.frameAutosaveName)
            self.window = window
            window.makeKeyAndOrderFront(nil)
        }
        authentication.refreshOnWindowOpen()
    }

    /// Builds the window `show` opens, apart from its delegate and saved frame, so tests can host
    /// the real shell in exactly this window.
    static func makeWindow(authentication: WeBeepAuthenticationController, router: ShellRouter) -> ConfigurationWindow {
        makeWindow(content: BeepbarShellView(authentication: authentication, recordings: authentication.recordings, router: router))
    }

    /// Shared window chrome and hosting options for the real app and isolated performance shell.
    static func makeWindow<Content: View>(content: Content) -> ConfigurationWindow {
        let controller = NSHostingController(rootView: content)
        // Only let SwiftUI enforce the minimum size; otherwise the window keeps resizing
        // itself to the content's ideal size on every page switch.
        controller.sizingOptions = [.minSize]
        let window = ConfigurationWindow(contentViewController: controller)
        window.title = "BeepBar"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.setContentSize(NSSize(width: 780, height: 680))
        window.minSize = NSSize(width: 680, height: 520)
        window.isReleasedWhenClosed = false
        // With no initial first responder, AppKit picks the first key view when the window is
        // ordered in, which in SwiftUI is its `KeyViewProxy`: once the window is key, that proxy
        // is presumably how SwiftUI hands focus to its first focusable view, on Corsi "Cerca
        // corsi". The hosting view refuses first responder, so this leaves the window itself
        // first responder, the same state a click outside a field leaves it in
        // (`ConfigurationWindow`).
        // Only checked in a window that isn't key, which tests can't make key.
        window.initialFirstResponder = controller.view
        return window
    }

    func windowWillClose(_ notification: Notification) {
        if let appearanceTrace {
            PerformanceTrace.shared.end("ui.configurationWindow", category: .ui, state: appearanceTrace)
        }
        appearanceTrace = nil
        // Drop the whole SwiftUI hierarchy once the window is gone, so that a closed window keeps
        // no view graph subscribed to the controller's @Published state: background syncs then
        // cost exactly what they cost without any UI. Deferred to the next main-actor turn so
        // AppKit finishes closing first; skipped if the window was reopened in the meantime.
        // This reuses the pre-existing delegate callback — no new AppKit→@MainActor entry point.
        Task { @MainActor [weak self] in
            guard let self, let window = self.window, !window.isVisible else { return }
            window.delegate = nil
            self.window = nil
            self.router.page = .home
            // Dropping the hierarchy doesn't reliably report the Recordings page as gone, and its
            // browser must not outlive the window (quiet at rest).
            self.authentication?.recordingsIfCreated?.windowClosed()
            // A course list load waiting for a sync to end is not wanted without a window (#98).
            self.authentication?.windowClosed()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let appearanceTrace else { return }
        PerformanceTrace.shared.end("ui.configurationWindow", category: .ui, state: appearanceTrace)
        self.appearanceTrace = nil
    }
}

/// The configuration window. A click anywhere outside a text field ends text editing, as people
/// expect from a page: AppKit only moves the focus to views that accept it, and nothing on Corsi
/// does apart from other text fields, so once "Cerca corsi" had the cursor no click on a row, a
/// switch or the background could take it away.
///
/// This lives in the window rather than in a SwiftUI tap gesture because it has to work for
/// every kind of click, including those on AppKit-backed controls (switches, menus, scrollers)
/// that never reach SwiftUI gestures. It only touches the window's own responder chain, never
/// controller state, so it adds no AppKit→`@MainActor` state access (see the hard rule on
/// `StatusItemController`).
///
/// Any click outside text counts, including the one that brings the window back from another
/// app and a drag of the window by its header: both are clicks somewhere else. A field that
/// should keep the cursor after one of its own SwiftUI buttons (the search field's clear button)
/// takes it back in that button's action.
final class ConfigurationWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        // Before dispatching, so the click still reaches its target: the switch still toggles,
        // the button still fires, and the field has already let go when it does.
        if event.type == .leftMouseDown,
           Self.clickEndsTextEditing(firstResponder: firstResponder, clickedView: contentView?.hitTest(event.locationInWindow)) {
            makeFirstResponder(nil)
        }
        super.sendEvent(event)
    }

    /// Whether a click on `clickedView` should end the text editing going on in `firstResponder`.
    /// Editing shows as the shared field editor being first responder. A click on text (the
    /// field editor itself, or any text field, which AppKit then focuses on its own) keeps
    /// editing; any other click, or one that hits nothing, ends it.
    static func clickEndsTextEditing(firstResponder: NSResponder?, clickedView: NSView?) -> Bool {
        guard let editor = firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return !(clickedView is NSText || clickedView is NSTextField)
    }
}
