import Sparkle

@MainActor final class UpdaterController {
    static let shared = UpdaterController()

    static var startsAutomatically: Bool {
#if DEBUG
        false
#else
        true
#endif
    }

    let controller = SPUStandardUpdaterController(startingUpdater: startsAutomatically, updaterDelegate: nil, userDriverDelegate: nil)

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
}
