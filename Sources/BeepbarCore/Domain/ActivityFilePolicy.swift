import Foundation
import UniformTypeIdentifiers

/// What a click on a file in Attività does.
public enum ActivityFileAction: Sendable, Equatable {
    /// Open it in its default app, as a double-click in Finder would.
    case open(URL)
    /// Show it selected in Finder instead of opening it (see `ActivityFilePolicy.opensDirectly`).
    case reveal(URL)
    /// BeepBar no longer knows the file, or it isn't where BeepBar put it (moved, renamed or
    /// deleted by the user): say so instead of opening something else.
    case missing
}

/// Decisions behind opening a file from Attività. The file is found by its remote id at click
/// time, through the sync database, so a file a later sync moved still opens; the activity list
/// itself only stores names.
public enum ActivityFilePolicy {
    /// Where the click leads, given where the database says the file is (`nil`: not tracked any
    /// more), whether something exists there, and whether it is an executable file (a file with
    /// the execute permission and no telling extension opens in Terminal and runs).
    public static func action(trackedPath: RelativePath?, root: URL, filename: String, fileExists: (URL) -> Bool, isExecutableFile: (URL) -> Bool) -> ActivityFileAction {
        guard let trackedPath, !ReservedNamespace.isReservedComponent(trackedPath.components.first ?? "") else { return .missing }
        let url = root.appending(path: trackedPath.value, directoryHint: .notDirectory)
        guard fileExists(url) else { return .missing }
        guard opensDirectly(filename: trackedPath.components.last ?? filename), !isExecutableFile(url) else { return .reveal(url) }
        return .open(url)
    }

    /// Course material is opened directly, except files macOS would *run* rather than show:
    /// apps, installers, scripts and command files (a `.command` opens Terminal and executes it),
    /// and links that open a web page or another file. A teacher's upload is not trusted to run
    /// with one click from BeepBar, so those are shown in Finder, where the user decides.
    public static func opensDirectly(filename: String) -> Bool {
        let fileExtension = (filename as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return true }
        if runnableExtensions.contains(fileExtension) { return false }
        guard let type = UTType(filenameExtension: fileExtension) else { return true }
        return !runnableTypes.contains { type.conforms(to: $0) }
    }

    private static let runnableTypes: [UTType] = [.executable, .applicationBundle, .application, .script, .shellScript, .appleScript, .osaScript, .internetLocation]

    /// Extensions that run or redirect on open but whose system type doesn't say so on every
    /// macOS version, listed explicitly so the decision doesn't depend on the installed apps.
    private static let runnableExtensions: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "bash", "zsh", "csh", "ksh", "fish",
        "pkg", "mpkg", "workflow", "action", "scpt", "scptd", "applescript", "jar",
        "prefpane", "saver", "webloc", "inetloc", "fileloc", "url",
    ]
}
