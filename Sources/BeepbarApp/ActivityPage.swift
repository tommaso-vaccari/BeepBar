import AppKit
import SwiftUI
import BeepbarCore

/// Opens or shows a file clicked in Attività. Behind a protocol so tests never open real apps.
@MainActor protocol ActivityFileOpening {
    func open(_ url: URL)
    func reveal(_ url: URL)
}

/// The real one: the file's default app, or Finder with the file selected. When no app can open
/// the file (a `.pages` without Pages), it is shown in Finder instead of the click doing nothing;
/// macOS isn't asked to prompt for an app first. `launch` and `show` are seams for tests.
struct WorkspaceFileOpener: ActivityFileOpening {
    typealias Launch = (URL, @escaping @Sendable (Bool) -> Void) -> Void
    var launch: Launch = { url, completion in
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in completion(error == nil) }
    }
    var show: @MainActor (URL) -> Void = { Finder.reveal($0) }

    func open(_ url: URL) {
        let show = show
        launch(url) { opened in
            guard !opened else { return }
            Task { @MainActor in show(url) }
        }
    }
    func reveal(_ url: URL) { show(url) }
}

/// Why a click on an Attività file did nothing, shown on its row.
enum ActivityItemProblem: Equatable {
    /// Not where BeepBar put it (moved, renamed, deleted, or replaced by a folder or a link).
    case missing
    /// macOS doesn't let BeepBar look at the file or a folder on the way.
    case unreadable
    /// The sync folder itself can't be reached (an unplugged disk, a moved folder).
    case folderUnavailable
    /// The sync database couldn't be read; this one can be temporary.
    case unavailable

    var message: String {
        switch self {
        case .missing: tr("Non è più dove BeepBar l’ha messo: forse l’hai spostato, rinominato o eliminato.", "It's no longer where BeepBar put it: you may have moved, renamed or deleted it.")
        case .unreadable: tr("BeepBar non ha il permesso di leggere questo file o la sua cartella.", "BeepBar isn't allowed to read this file or its folder.")
        case .folderUnavailable: tr("La cartella dei materiali non è raggiungibile: forse è su un disco scollegato o è stata spostata.", "The materials folder can't be reached: it may be on a disconnected disk or have been moved.")
        case .unavailable: tr("BeepBar non è riuscita a controllare questo file. Riprova tra poco.", "BeepBar couldn't check this file. Try again shortly.")
        }
    }
}

/// Opens nothing: the default for test controllers.
struct InertFileOpener: ActivityFileOpening {
    func open(_ url: URL) {}
    func reveal(_ url: URL) {}
}

/// What the last synchronization brought in, course by course.
struct ActivityPage: View {
    @ObservedObject var authentication: WeBeepAuthenticationController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let summary = authentication.lastSyncSummary {
                    SectionHeader(title: tr("Ultima sincronizzazione", "Last sync"), subtitle: summary.completedAt.shortText)
                        .uiContentReady(.activity)
                    HStack(spacing: 8) {
                        MetricTile(value: summary.added, label: tr("Nuovi", "New"), systemImage: "plus.circle.fill", tint: .green)
                        MetricTile(value: summary.updated, label: tr("Aggiornati", "Updated"), systemImage: "arrow.triangle.2.circlepath.circle.fill", tint: .blue)
                        MetricTile(value: summary.preservedLocal, label: tr("Modifiche tue", "Your changes"), systemImage: "lock.circle.fill", tint: .purple)
                        MetricTile(value: summary.failures, label: tr("Non aggiornati", "Not updated"), systemImage: "exclamationmark.triangle.fill", tint: .orange)
                    }
                    if summary.affectedCourses.isEmpty {
                        ContentUnavailableView(tr("Nessun corso con nuovi materiali", "No courses with new materials"), systemImage: "checkmark.circle", description: Text(tr("Tutto era già aggiornato.", "Everything was already up to date.")))
                            .frame(minHeight: 220)
                            .frame(maxWidth: .infinity)
                            .card()
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(summary.affectedCourses) { course in
                                CourseActivityCard(
                                    course: course,
                                    platformName: authentication.selectedSite.platformName,
                                    folderURL: authentication.rootURL?.appending(path: course.courseFolder, directoryHint: .isDirectory),
                                    problems: authentication.activityItemProblems,
                                    openItem: { id, name, showInFinder in
                                        Task { await authentication.openActivityItem(id: id, name: name, showInFinder: showInFinder) }
                                    }
                                )
                            }
                        }
                    }
                } else {
                    SectionHeader(title: tr("Ultima sincronizzazione", "Last sync"))
                    ContentUnavailableView(tr("Nessuna sincronizzazione recente", "No recent sync"), systemImage: "clock", description: Text(tr("Qui troverai i materiali arrivati con l’ultima sincronizzazione.", "Materials from the last sync will show up here.")))
                        .frame(minHeight: 260)
                        .frame(maxWidth: .infinity)
                        .card()
                }
            }
            .padding(BeepbarStyle.pagePadding)
        }
    }
}

private struct CourseActivityCard: View {
    let course: CourseSyncCount
    let platformName: String
    let folderURL: URL?
    let problems: [String: ActivityItemProblem]
    /// (remote id, name, show in Finder instead of opening).
    let openItem: (String, String, Bool) -> Void
    @State private var isExpanded = false
#if DEBUG
    @Environment(\.uiFixtureExpandedActivity) private var fixtureExpanded
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(BeepbarStyle.snappy) { isExpanded.toggle() } } label: {
                HStack(spacing: 12) {
                    SymbolTile(systemImage: "folder.fill", size: 30)
                    Text(course.courseFolder)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if course.added > 0 { CountPill(text: course.addedLabel, tint: .green) }
                    if course.updated > 0 { CountPill(text: course.updatedLabel, tint: .blue) }
                    if course.moved > 0 { CountPill(text: course.movedLabel, tint: .teal) }
                    if course.keptInPlace > 0 { CountPill(text: course.keptInPlaceLabel, tint: .purple) }
                    if course.courseFailure != nil { CountPill(text: tr("non sincronizzato", "not synced"), tint: .orange) }
                    if !course.failedItems.isEmpty { CountPill(text: tr("\(course.failedItems.count) non aggiornati", "\(course.failedItems.count) not updated"), tint: .orange) }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? tr("Comprimi", "Collapse") : tr("Espandi", "Expand"))

#if DEBUG
            Color.clear.frame(height: 0).onAppear {
                if fixtureExpanded { isExpanded = true }
            }
#endif
            if isExpanded {
                Divider().padding(.leading, 56)
                VStack(alignment: .leading, spacing: 7) {
                    if let failure = course.courseFailure {
                        Label {
                            Text(failure).font(.callout)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    ForEach(course.items) { item in
                        fileRow(id: item.id, name: item.name) {
                            Text(item.name).font(.callout).lineLimit(1)
                        } icon: {
                            Image(systemName: item.kind == .added ? "plus.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                                .foregroundStyle(item.kind == .added ? .green : .blue)
                        }
                        .uiContentReady(.expandedActivity, enabled: item.id == course.items.first?.id)
                    }
                    ForEach(course.movedItems) { item in
                        fileRow(id: item.id, name: item.name) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.callout).lineLimit(1)
                                Text(item.explanation(platform: platformName)).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: item.outcome == .moved ? "arrow.right.circle.fill" : "lock.circle.fill")
                                .foregroundStyle(item.outcome == .moved ? .teal : .purple)
                        }
                    }
                    ForEach(course.failedItems) { item in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).font(.callout).lineLimit(1)
                                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    if let folderURL {
                        Button(tr("Mostra nel Finder", "Show in Finder"), systemImage: "folder") { Finder.reveal(folderURL) }
                            .buttonStyle(.link)
                            .font(.callout)
                            .padding(.top, 2)
                    }
                }
                .symbolRenderingMode(.hierarchical)
                .padding(.leading, 56)
                .padding(.trailing, 14)
                .padding(.vertical, 12)
                .transition(.opacity)
            }
        }
        .card(padding: 0)
        .clipShape(RoundedRectangle(cornerRadius: BeepbarStyle.cardRadius, style: .continuous))
    }

    /// A file that arrived or moved: a click opens it, the context menu also shows it in Finder.
    /// Failed items aren't rows like this: there is no file to open.
    private func fileRow<Title: View, Icon: View>(id: String, name: String, @ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) -> some View {
        ActivityFileRow(action: ActivityClickAction(filename: name), name: name, problem: problems[id], title: title(), icon: icon()) { showInFinder in
            openItem(id, name, showInFinder)
        }
    }
}

/// What a click on an Attività file does, worded for the user: on hover, in the tooltip, for
/// VoiceOver and in the context menu. Derived from `ActivityFilePolicy.opensDirectly`, so a file
/// whose name is only shown in Finder is never labelled "Apri". It's a prediction from the name
/// alone: the click itself is decided against the disk (`ActivityFilePolicy.action`), so a
/// document the user made executable is still only shown in Finder even though it says "Apri".
/// The label can only err that way round, never promising Finder and then opening.
enum ActivityClickAction: Equatable {
    case open
    case showInFinder

    init(filename: String) {
        self = ActivityFilePolicy.opensDirectly(filename: filename) ? .open : .showInFinder
    }

    var title: String {
        switch self {
        case .open: tr("Apri", "Open")
        case .showInFinder: tr("Mostra nel Finder", "Show in Finder")
        }
    }

    var systemImage: String {
        switch self {
        case .open: "arrow.up.forward.square"
        case .showInFinder: "folder"
        }
    }

    func help(for name: String) -> String {
        switch self {
        case .open: tr("Apri “\(name)”", "Open “\(name)”")
        case .showInFinder: tr("Mostra “\(name)” nel Finder", "Show “\(name)” in Finder")
        }
    }

    var accessibilityHint: String {
        switch self {
        case .open: tr("Apre il file", "Opens the file")
        case .showInFinder: tr("Mostra il file nel Finder", "Shows the file in Finder")
        }
    }
}

/// One clickable file in an Attività card. On hover it shows what a click will do ("Apri" or
/// "Mostra nel Finder") at the trailing edge, and the pointer becomes the link hand, so it reads
/// as clickable without adding text to the list at rest. The hint keeps its space when hidden
/// (opacity, not removal), so names don't shift while the pointer moves across rows.
private struct ActivityFileRow<Title: View, Icon: View>: View {
    let action: ActivityClickAction
    let name: String
    let problem: ActivityItemProblem?
    let title: Title
    let icon: Icon
    /// `true` for the context menu's "Mostra nel Finder".
    let open: (Bool) -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { open(false) } label: {
                HStack(spacing: 8) {
                    Label { title } icon: { icon }
                    Spacer(minLength: 8)
                    Label(action.title, systemImage: action.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .opacity(isHovered ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .modifier(LinkPointer())
            .help(action.help(for: name))
            .accessibilityHint(action.accessibilityHint)
            .contextMenu {
                if action == .open { Button(ActivityClickAction.open.title) { open(false) } }
                Button(ActivityClickAction.showInFinder.title) { open(true) }
            }
            if let problem {
                Text(problem.message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 28)
            }
        }
    }
}

/// The link pointer on macOS 15 and later; macOS 14 keeps the arrow rather than pushing and
/// popping `NSCursor`, which leaves the cursor stack unbalanced when a hovered row disappears.
private struct LinkPointer: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(.link)
        } else {
            content
        }
    }
}

private extension MovedSyncItem {
    /// Where the file went, or why it stayed. Built at display time so it follows a language switch.
    func explanation(platform: String) -> String {
        let place = folder.isEmpty ? tr("nella cartella del corso", "in the course folder") : tr("in “\(folder)”", "to “\(folder)”")
        switch outcome {
        case .moved:
            return tr("Spostato \(place), come su \(platform)", "Moved \(place), as on \(platform)")
        case .keptEdited:
            let location = folder.isEmpty ? tr("nella cartella del corso", "in the course folder") : tr("in “\(folder)”", "in “\(folder)”")
            return tr("Su \(platform) ora è \(location). L’hai modificato: scegli in Conflitti se spostarlo", "Now \(location) on \(platform). You edited it: choose in Conflicts whether to move it")
        }
    }
}
