import Foundation
import UniformTypeIdentifiers

/// What sits at a tracked path, as `FileStore.openableFileState` sees it.
public enum OpenableFileState: Sendable, Equatable {
    case missing
    /// A folder, or a symbolic link at the file or in a folder on the way: not what BeepBar wrote.
    case notARegularFile
    /// BeepBar has no permission to look at the file or a folder on the way.
    case unreadable
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
    /// BeepBar isn't allowed to look at it: say so, open nothing.
    case unreadable
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
        case .unreadable:
            return .unreadable
        case .regular(let executable):
            guard !executable, opensDirectly(filename: trackedPath.components.last ?? "") else { return .reveal(url) }
            return .open(url)
        }
    }

    /// Only documents open directly: PDF, images, audio and video, presentations, spreadsheets,
    /// ebooks, Word, OpenDocument and Pages files, RTF, plain text, Markdown, CSV/TSV and zip
    /// archives (opening one only extracts it). Anything else is shown in Finder, where the user
    /// decides: apps, installers, disk images, scripts and source code in any language, web
    /// pages and XML (an SVG can carry script a browser would run), Terminal session files,
    /// playlists, configuration profiles, shortcuts, links, macro-enabled Office formats, TeX,
    /// stream metafiles, and any type macOS doesn't know. Some documents that open can hold
    /// macros and rely on their app's own protection before any macro runs: legacy Office files
    /// (`.doc`, `.xls`, `.xlt`, `.xlw`, `.ppt`, `.pps`, `.pot`, behind Office's prompt) and
    /// OpenDocument files (`.odt`, `.ods`, `.odp`, behind LibreOffice's macro security).
    public static func opensDirectly(filename: String) -> Bool {
        let fileExtension = (filename as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty, !isExcluded(fileExtension: fileExtension) else { return false }
        guard let type = UTType(filenameExtension: fileExtension), !type.isDynamic else { return false }
        guard !runnableTypes.contains(where: { type.conforms(to: $0) }) else { return false }
        return exactDocumentTypes.contains(type.identifier) || documentFamilies.contains { type.conforms(to: $0) }
    }

    /// Families matched by conformance: their members are media and office documents.
    private static let documentFamilies: [UTType] = [.pdf, .image, .audiovisualContent, .presentation, .spreadsheet, .epub]

    /// Matched by exact identifier, not by conformance: any installed app can declare its own
    /// type as conforming to plain text or zip (TeXShop does for `.lua` and `.dtx`, Music for
    /// `.m3u` playlists) and then become its default app.
    private static let exactDocumentTypes: Set<String> = [
        "public.plain-text", "public.utf8-plain-text", "public.utf16-plain-text", "net.daringfireball.markdown",
        "public.comma-separated-values-text", "public.tab-separated-values-text", "public.rtf", "public.zip-archive",
        "org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "org.oasis-open.opendocument.text",
        "com.apple.iwork.pages.sffpages", "com.apple.iwork.pages.sections", "com.apple.iwork.pages.pages",
    ]

    /// Checked first: some of these also conform to a document family above (an SVG is an image).
    private static let runnableTypes: [UTType] = [.sourceCode, .script, .executable, .application, .applicationBundle, .bundle, .package, .internetLocation, .diskImage, .xml, .html]

    /// Extensions refused regardless of the type macOS assigns, so the decision doesn't depend on
    /// the macOS version or the installed apps. On macOS 27 most of them are already caught by
    /// their type (a macro-enabled workbook conforms to `public.executable`), but that is a
    /// property of the system's type declarations, which apps and versions change; this list is
    /// what keeps them refused everywhere. Covers macro-enabled Office (incl. `.xlsb`), TeX
    /// (a TeX editor with shell escape can run commands), PostScript (a program), stream
    /// metafiles that send a player to URLs the uploader chose (`.ram`, `.rpm`, `.sdp`), and
    /// Terminal and shell files.
    static func isExcluded(fileExtension: String) -> Bool {
        excludedExtensions.contains(fileExtension.lowercased())
    }

    static let excludedExtensions: Set<String> = [
        "docm", "dotm", "xlsm", "xltm", "xlam", "xlsb", "pptm", "potm", "ppsm", "ppam",
        "tex", "ltx", "latex", "sty", "cls", "bib",
        "ps", "eps", "epsf", "epsi",
        "ram", "rpm", "sdp",
        "command", "tool", "terminal", "term", "sh", "tcl",
    ]
}
