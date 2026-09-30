import AppKit
import BeepbarCore
import SwiftUI
import os

enum BeepbarLog {
    static let lifecycle = Logger(subsystem: "io.github.tvaccari.beepbar", category: "lifecycle")
    static let scheduler = Logger(subsystem: "io.github.tvaccari.beepbar", category: "scheduler")
    static let sync = Logger(subsystem: "io.github.tvaccari.beepbar", category: "sync")
}

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

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    // Owned here, not by the SwiftUI App struct: for a window-less scene, SwiftUI doesn't
    // guarantee `body` runs before applicationDidFinishLaunching, so a reference handed over
    // from `body` can still be nil when this fires. AppKit does guarantee the delegate itself
    // is fully constructed and assigned before that call, so creating the controller here
    // removes the race entirely.
    let authentication = WeBeepAuthenticationController()
    private var statusItemController: StatusItemController?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        BeepbarLog.lifecycle.notice("Application launched version=\(version, privacy: .public) build=\(build, privacy: .public)")
        _ = UpdaterController.shared
        statusItemController = StatusItemController(authentication: authentication)
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-preview") {
            ConfigurationWindowController.shared.show(authentication)
            return
        }
#endif
        guard authentication.needsOnboarding else { return }
        ConfigurationWindowController.shared.show(authentication)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let syncTask = authentication.prepareForTermination() else {
            BeepbarLog.lifecycle.notice("Termination accepted immediately")
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
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    @MainActor private static func setSymbol(_ symbol: String, on statusItem: NSStatusItem) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "BeepBar")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let snapshot = authentication.menuBarSnapshot

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
        actionItem.target = self
        menu.addItem(actionItem)

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: snapshot.openTitle, action: #selector(openConfiguration), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let quitItem = NSMenuItem(title: snapshot.quitTitle, action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
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

    @objc private func quit() {
        BeepbarLog.lifecycle.notice("Menu quit selected")
        Task { @MainActor in NSApp.terminate(nil) }
    }
}

@MainActor final class ConfigurationWindowController: NSObject, NSWindowDelegate {
    static let shared = ConfigurationWindowController()
    private var window: NSWindow?
    private var appearanceTrace: OSSignpostIntervalState?
    private let router = ShellRouter()
    private static let frameAutosaveName = "BeepbarConfigurationWindow"

    func show(_ authentication: WeBeepAuthenticationController, page: ShellPage? = nil) {
        BeepbarLog.lifecycle.notice("Configuration window requested")
        if window?.isKeyWindow != true {
            if let appearanceTrace {
                PerformanceTrace.shared.end("ui.configurationWindow", category: .ui, state: appearanceTrace)
            }
            appearanceTrace = PerformanceTrace.shared.begin("ui.configurationWindow", category: .ui)
        }
        if let page { router.page = page }
        // Activate before ordering the window in: with macOS 14+ cooperative activation the
        // deprecated `activate(ignoringOtherApps:)` is ignored, which left the window open but
        // inactive, so the first click only activated the app and seemed to do nothing.
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            let controller = NSHostingController(rootView: BeepbarShellView(authentication: authentication, router: router))
            // Only let SwiftUI enforce the minimum size; otherwise the window keeps resizing
            // itself to the content's ideal size on every page switch.
            controller.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: controller)
            window.title = "BeepBar"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 780, height: 680))
            window.minSize = NSSize(width: 680, height: 520)
            window.isReleasedWhenClosed = false
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
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let appearanceTrace else { return }
        PerformanceTrace.shared.end("ui.configurationWindow", category: .ui, state: appearanceTrace)
        self.appearanceTrace = nil
    }
}
