import AppKit

// Standalone AppKit probe for BeepBar's quit paths (not BeepBar itself: its own bundle id, no
// BeepBar data). Run it through `scripts/quit-probe.sh`, which builds it and checks every mode.
//
// It reproduces the hang behind `WeBeepAuthenticationController.prepareForMenuQuit()`: when
// `NSApp.terminate(nil)` is called from inside a main-queue job and the delegate answers
// `.terminateLater`, AppKit's nested loop never runs main-actor work, so the reply never comes.
//
// Modes (the expected outcome is checked by the script):
//   menu-legacy    "Esci" as it was: terminate inside the hop, delegate waits    → HUNG
//   menu-dispatch  the same with DispatchQueue.main.async                        → HUNG
//   menu           "Esci" as it is now: drain first, then terminate, terminateNow → QUIT
//   external       quit from outside (osascript, like Sparkle or logout) while a
//                  sync is pending: delegate waits with terminateLater           → QUIT
let mode = CommandLine.arguments.dropFirst().first ?? "external"
let hangAfter: TimeInterval = mode == "external" ? 12 : 5

func report(_ line: String) {
    print(line)
    fflush(stdout)
}

// Watchdog off the main thread: if the process is still alive, the quit hung.
Thread.detachNewThread {
    Thread.sleep(forTimeInterval: hangAfter)
    report("RESULT \(mode) HUNG")
    exit(2)
}

/// Stands in for BeepBar's sync task: runs on the main actor and needs it to wind down.
@MainActor final class FakeSync {
    private(set) var task: Task<Void, Never>?

    func start() {
        task = Task { @MainActor in
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
            // Winding down still needs the main actor, as BeepBar's finalization does.
            try? await Task.sleep(for: .milliseconds(200))
            report("  sync stopped")
        }
    }
}

@MainActor final class Delegate: NSObject, NSApplicationDelegate {
    let sync = FakeSync()
    /// Mirrors `menuQuitDrained`.
    var menuQuitDrained = false
    var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        sync.start()
        switch mode {
        case "menu-legacy":
            Task { @MainActor in NSApp.terminate(nil) }
        case "menu-dispatch":
            DispatchQueue.main.async { NSApp.terminate(nil) }
        case "menu":
            // Mirrors StatusItemController.quit() → prepareForMenuQuit().
            Task { @MainActor in
                if let task = self.sync.task {
                    task.cancel()
                    await Self.wait(for: task, atMost: .seconds(5))
                }
                self.menuQuitDrained = true
                NSApp.terminate(nil)
            }
        case "external":
            report("READY")
        default:
            report("unknown mode \(mode)")
            exit(64)
        }
    }

    /// Mirrors AppDelegate.applicationShouldTerminate.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if menuQuitDrained { return .terminateNow }
        guard let task = sync.task else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        task.cancel()
        Task { @MainActor in
            await task.value
            self.finish()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            self.finish()
        }
        return .terminateLater
    }

    private func finish() {
        guard terminationPending else { return }
        terminationPending = false
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        report("RESULT \(mode) QUIT")
    }

    /// Mirrors `WeBeepAuthenticationController.wait(for:atMost:)`.
    nonisolated static func wait(for task: Task<Void, Never>, atMost timeout: Duration) async {
        final class Gate: @unchecked Sendable {
            let lock = NSLock()
            var continuation: CheckedContinuation<Void, Never>?
            func resume() {
                lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
                pending?.resume()
            }
        }
        let gate = Gate()
        await withCheckedContinuation { continuation in
            gate.continuation = continuation
            Task { await task.value; gate.resume() }
            Task { try? await Task.sleep(for: timeout); gate.resume() }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
app.run()
