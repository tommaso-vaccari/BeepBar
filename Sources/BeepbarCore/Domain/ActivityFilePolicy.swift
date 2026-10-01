import Foundation
import UniformTypeIdentifiers

/// What sits at a tracked path, as `FileStore.openableFileState` sees it.
public enum OpenableFileState: Sendable, Equatable {
    case missing
    /// A folder, or a symbolic link at the file or in a folder on the way: not what BeepBar wrote.
    case notARegularFile
    case regular(executable: Bool)
}

/// What a click on a file in Attività does.
public enum ActivityFileAction: Sendable, Equatable {
    /// Open it in its default app, as a double-click in Finder would.
    case open(URL)
    /// Show it selected in Finder instead of opening it (see `ActivityFilePolicy.opensDirectly`).
    case reveal(URL)
    /// BeepBar no longer tracks the file, or what is at its path isn't the file BeepBar wrote
    /// (moved, renamed, deleted, or replaced by a folder or a link): say so, open nothing.
    case missing
}

/// Decisions behind opening a file from Attività (#69). The file is found by its remote id at
/// click time, through the sync database, so a file a later sync moved still opens; the activity
/// list itself only stores names.
///
/// Downloaded course files carry no quarantine flag, so Gatekeeper would not warn before anything
/// they run: the only protection is what BeepBar agrees to open. Hence an allowlist of document
/// types; everything else, including types BeepBar doesn't recognize, is only shown in Finder.
public enum ActivityFilePolicy {
    /// Where the click leads, given where the database says the file is (`nil`: not tracked any
    /// more) and what is there now.
    public static func action(trackedPath: RelativePath?, root: URL, fileState: OpenableFileState) -> ActivityFileAction {
        guard let trackedPath, !ReservedNamespace.isReservedComponent(trackedPath.components.first ?? "") else { return .missing }
        let url = root.appending(path: trackedPath.value, directoryHint: .notDirectory)
        switch fileState {
        case .missing, .notARegularFile:
            return .missing
        case .regular(let executable):
            guard !executable, opensDirectly(filename: trackedPath.components.last ?? "") else { return .reveal(url) }
            return .open(url)
        }
    }

    /// Only documents open directly: PDF, images, audio and video, office, iWork and OpenDocument
    /// files, plain text, and zip archives (opening one only extracts it). Anything else is shown
    /// in Finder, where the user decides: apps, installers, disk images, scripts in any language,
    /// Terminal session files (`.term`, `.terminal`), configuration profiles, shortcuts, links,
    /// macro-enabled office files, and any type macOS doesn't know.
    public static func opensDirectly(filename: String) -> Bool {
        let fileExtension = (filename as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty, !excludedExtensions.contains(fileExtension) else { return false }
        guard let type = UTType(filenameExtension: fileExtension), !type.isDynamic else { return false }
        guard !runnableTypes.contains(where: { type.conforms(to: $0) }) else { return false }
        return documentTypes.contains { type.conforms(to: $0) }
    }

    private static let documentTypes: [UTType] = [
        .pdf, .image, .audiovisualContent, .presentation, .spreadsheet, .rtf, .rtfd,
        .plainText, .commaSeparatedText, .tabSeparatedText, .zip, .epub,
    ] + [
        "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc",
        "org.oasis-open.opendocument.text", "com.apple.iwork.pages.sffpages", "com.apple.iwork.pages.sections", "com.apple.iwork.pages.pages",
    ].compactMap { UTType($0) }

    /// Checked first: some of these also conform to a document type above (a script is plain text).
    private static let runnableTypes: [UTType] = [.sourceCode, .script, .executable, .application, .applicationBundle, .bundle, .package, .internetLocation, .diskImage]

    /// Extensions refused regardless of the type macOS assigns: macro-enabled office files conform
    /// to their plain counterparts; TeX sources are plain text, but a TeX editor with shell escape
    /// can run commands from them; and these names must stay refused on every macOS version.
    private static let excludedExtensions: Set<String> = [
        "docm", "dotm", "xlsm", "xltm", "xlam", "pptm", "potm", "ppsm", "ppam",
        "tex", "ltx", "latex", "sty", "cls", "bib",
        "command", "tool", "terminal", "term", "sh", "tcl",
    ]
}
