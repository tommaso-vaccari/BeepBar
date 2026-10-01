import SwiftUI
import BeepbarCore

struct HomePage: View {
    @ObservedObject var authentication: WeBeepAuthenticationController
    let open: (ShellPage) -> Void
    @State private var organizingCourse: RemoteCourseSummary?
    @State private var editingCourseID: Int64?
    @State private var query = ""

    // The status card stays put; only the course list scrolls, inside its own box that takes
    // whatever height the window leaves.
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SyncHeroCard(authentication: authentication, open: open)
            coursesSection
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(BeepbarStyle.pagePadding)
        // A sync makes renames impossible; drop a pending edit instead of resurrecting it later.
        .onChange(of: authentication.isSyncActive) { _, active in
            if active { editingCourseID = nil }
        }
        .sheet(item: $organizingCourse) { course in
            ModuleDestinationsSheet(authentication: authentication, course: course)
        }
    }

    // MARK: Courses

    private var enabledCount: Int {
        authentication.courses.reduce(0) { $0 + (authentication.isCourseEnabled($1) ? 1 : 0) }
    }

    private var filteredCourses: [RemoteCourseSummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return authentication.courses }
        return authentication.courses.filter {
            authentication.folder(for: $0).localizedStandardContains(needle)
                || $0.displayName.localizedStandardContains(needle)
                || $0.shortName.localizedStandardContains(needle)
        }
    }

    private var coursesSection: some View {
        let rows = filteredCourses
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: tr("Corsi", "Courses"),
                subtitle: authentication.courses.isEmpty ? nil : tr("\(enabledCount) di \(authentication.courses.count) sincronizzati", "\(enabledCount) of \(authentication.courses.count) synced")
            ) {
                // Stays visible while a query is active, so a filter can never linger unseen.
                if authentication.courses.count > 6 || !query.isEmpty { searchField }
                refreshButton
            }
            if let error = authentication.courseLoadError {
                NoticeBanner(text: error.text, systemImage: "wifi.exclamationmark", tint: .red)
            }
            if authentication.courses.isEmpty {
                emptyCourses
                    .frame(maxHeight: .infinity)
                    .frame(maxWidth: .infinity)
                    .card()
            } else if rows.isEmpty {
                ContentUnavailableView {
                    Label(tr("Nessun corso trovato", "No courses found"), systemImage: "magnifyingglass")
                } description: {
                    Text(tr("Nessun corso corrisponde a “\(query)”.", "No course matches “\(query)”."))
                } actions: {
                    Button(tr("Cancella ricerca", "Clear search")) { query = "" }
                }
                .frame(maxHeight: .infinity)
                    .frame(maxWidth: .infinity)
                    .card()
            } else {
                courseList(rows)
            }
        }
    }

    private func courseList(_ rows: [RemoteCourseSummary]) -> some View {
        let organizeDisabled = authentication.isSyncActive || authentication.recoveryBlocked || authentication.accountState != .connected || authentication.rootURL == nil
        return ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { course in
                    let folder = authentication.folder(for: course)
                    CourseRow(
                        course: course,
                        folder: folder,
                        isEnabled: authentication.isCourseEnabled(course),
                        isRenaming: authentication.renamingCourseID == course.id,
                        renameError: authentication.courseRenameErrors[course.id],
                        toggleDisabled: authentication.isSyncActive || authentication.isLoadingCourses,
                        // renameFolder() is a no-op during a sync or a blocked recovery.
                        renameDisabled: authentication.isSyncActive || authentication.recoveryBlocked,
                        organizeDisabled: organizeDisabled,
                        folderURL: authentication.rootURL?.appending(path: folder, directoryHint: .isDirectory),
                        authentication: authentication,
                        isEditing: editingCourseID == course.id,
                        setEditing: { editingCourseID = $0 ? course.id : nil },
                        organize: { organizingCourse = course }
                    )
                    if course.id != rows.last?.id {
                        Divider().padding(.leading, 58)
                    }
                }
            }
        }
        .frame(minHeight: 140, maxHeight: .infinity)
        .card(padding: 0)
        .clipShape(RoundedRectangle(cornerRadius: BeepbarStyle.cardRadius, style: .continuous))
    }

    private var emptyCourses: some View {
        let site = authentication.selectedSite.platformName
        let description: String = if authentication.courseLoadError != nil {
            tr("Riprova con il pulsante di aggiornamento.", "Try again with the refresh button.")
        } else if authentication.hasStoredCredential {
            tr("Nessun corso disponibile su \(site).", "No courses available on \(site).")
        } else {
            tr("Collega \(site) per caricare l’elenco dei corsi.", "Connect \(site) to load your course list.")
        }
        return ContentUnavailableView {
            Label(authentication.isLoadingCourses ? tr("Caricamento corsi…", "Loading courses…") : tr("Nessun corso caricato", "No courses loaded"), systemImage: "books.vertical")
        } description: {
            Text(description)
        } actions: {
            if !authentication.hasStoredCredential {
                Button(tr("Accedi a \(site)", "Sign in to \(site)")) { open(.settings) }
            }
        }
        .frame(minHeight: 140)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(tr("Cerca corso", "Search courses"), text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(tr("Cancella ricerca", "Clear search"))
            }
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(width: 200)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
    }

    private var refreshButton: some View {
        Button { authentication.loadCourses() } label: {
            ZStack {
                ProgressView().controlSize(.small).opacity(authentication.isLoadingCourses ? 1 : 0)
                Image(systemName: "arrow.clockwise").opacity(authentication.isLoadingCourses ? 0 : 1)
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .help(tr("Aggiorna l’elenco dei corsi", "Refresh the course list"))
        .accessibilityLabel(tr("Aggiorna corsi", "Refresh courses"))
        .disabled(authentication.accountState != .connected || authentication.isLoadingCourses || authentication.isSyncActive)
    }
}

// MARK: - Sync status

/// Compact status strip: brand + state, one quiet line of facts, one control. A single accent
/// color (the button) so nothing competes with the action; numbers carry weight through type,
/// not through colored chips. Detailed figures live on the Attività tab.
private struct SyncHeroCard: View {
    @ObservedObject var authentication: WeBeepAuthenticationController
    let open: (ShellPage) -> Void
    @State private var showAbandonConfirmation = false

    private var state: AppSyncState { authentication.syncState }
    /// "Risparmio dati" holding automatic sync back, when it is what the card shows (see
    /// `WeBeepAuthenticationController.visibleDataSaverPause`). It takes the headline, the badge
    /// and the explanation line; "· sincronizzato X fa" stays, since that is still true.
    private var pause: DataSaverPause? { authentication.visibleDataSaverPause }
    private var badgeSymbol: String? { pause == nil ? state.badgeSymbol : "pause.circle.fill" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                BeepbarLogo(size: 44, badge: badgeSymbol, badgeTint: pause == nil ? state.tint : .gray, accessibilityLabel: "BeepBar, \(pause?.title ?? state.title)")
                VStack(alignment: .leading, spacing: 3) {
                    // The relative time ticks once a minute, and only while the window exists.
                    TimelineView(.everyMinute) { context in
                        headlineText(now: context.date)
                            .lineLimit(1)
                    }
                    secondaryLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 4) {
                    primaryAction
                    if authentication.accountState == .connected {
                        automaticMenu
                    }
                }
            }
            if authentication.isSyncActive {
                SyncProgressLine(progressStore: authentication.progressStore)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !authentication.conflicts.isEmpty || !authentication.remoteChanges.isEmpty {
                conflictsBanner
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .card(padding: 0)
        .animation(BeepbarStyle.snappy, value: authentication.isSyncActive)
        .animation(BeepbarStyle.snappy, value: authentication.conflicts.count)
        .animation(BeepbarStyle.snappy, value: badgeSymbol)
        .confirmationDialog(tr("Abbandonare lo spostamento del modulo?", "Abandon the module move?"), isPresented: $showAbandonConfirmation, titleVisibility: .visible) {
            Button(tr("Abbandona spostamento", "Abandon move"), role: .destructive) { authentication.abandonPendingModuleMoves() }
            Button(tr("Annulla", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("Nessun file viene spostato né eliminato: BeepBar registra dove si trova ogni file e il modulo mantiene la cartella precedente.", "No files are moved or deleted: BeepBar records where each file is and the module keeps its previous folder."))
        }
    }

    private var headline: String {
        // Not "Tutto aggiornato" while paused: new material may be waiting on Moodle.
        if let pause { return pause.title }
        if case .synced = state { return tr("Tutto aggiornato", "All up to date") }
        return state.title
    }

    // "Tutto aggiornato  ·  sincronizzato 9 minuti fa"
    private func headlineText(now: Date) -> Text {
        let title = Text(headline).font(.title3.weight(.semibold))
        guard !authentication.isSyncActive,
              let summary = authentication.lastSyncSummary,
              summary.completedAt.timeIntervalSince1970 > 0 else { return title }
        let when = now.timeIntervalSince(summary.completedAt) < 60
            ? tr("adesso", "just now")
            : summary.completedAt.formatted(.relative(presentation: .named).locale(BeepbarStyle.locale))
        return title
            + Text("  ·  ").font(.callout).foregroundStyle(.tertiary)
            + Text(tr("sincronizzato \(when)", "synced \(when)")).font(.callout).foregroundStyle(.secondary)
    }

    // "12 nuovi · 4 aggiornati · 1 tua modifica protetta   Dettagli ›" — or the state's own explanation.
    @ViewBuilder private var secondaryLine: some View {
        if let pause {
            Text(pause.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } else if !authentication.isSyncActive, let summary = authentication.lastSyncSummary {
            HStack(spacing: 10) {
                summaryText(summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if summary.hasDetail {
                    Button { open(.activity) } label: {
                        HStack(spacing: 2) {
                            Text(tr("Dettagli", "Details"))
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        }
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                    .help(tr("Vedi cosa è arrivato, corso per corso", "See what arrived, course by course"))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if authentication.recoveryBlocked && authentication.hasPendingModuleMoves {
                    Button(tr("Abbandona spostamento…", "Abandon move…")) { showAbandonConfirmation = true }
                        .buttonStyle(.link)
                        .font(.callout)
                        .disabled(authentication.isSyncActive)
                }
            }
        }
    }

    private func summaryText(_ summary: SyncCompletionSummary) -> Text {
        func figure(_ value: Int, _ one: String, _ many: String) -> Text {
            Text("\(value)").fontWeight(.semibold).foregroundStyle(.primary)
                + Text(" " + (value == 1 ? one : many))
        }
        var parts: [Text] = []
        if summary.added > 0 { parts.append(figure(summary.added, tr("nuovo", "new"), tr("nuovi", "new"))) }
        if summary.updated > 0 { parts.append(figure(summary.updated, tr("aggiornato", "updated"), tr("aggiornati", "updated"))) }
        if summary.moved > 0 { parts.append(figure(summary.moved, tr("spostato", "moved"), tr("spostati", "moved"))) }
        if summary.preservedLocal > 0 { parts.append(figure(summary.preservedLocal, tr("tua modifica protetta", "local change kept"), tr("tue modifiche protette", "local changes kept"))) }
        // `failures` also counts whole courses that failed; split them like `partialDetail` does.
        let failedCourses = summary.perCourse.filter { $0.courseFailure != nil }.count
        let failedFiles = max(0, summary.failures - failedCourses)
        if failedCourses > 0 {
            parts.append(Text(failedCourses == 1 ? tr("1 corso non accessibile", "1 course not accessible") : tr("\(failedCourses) corsi non accessibili", "\(failedCourses) courses not accessible")).fontWeight(.semibold).foregroundStyle(.orange))
        }
        if failedFiles > 0 {
            parts.append(Text(tr("\(failedFiles) non aggiornati", "\(failedFiles) not updated")).fontWeight(.semibold).foregroundStyle(.orange))
        }
        if parts.isEmpty { parts.append(Text(tr("Nessuna novità", "Nothing new"))) }
        var text = parts[0]
        for part in parts.dropFirst() { text = text + Text("  ·  ").foregroundStyle(.tertiary) + part }
        return text.font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder private var primaryAction: some View {
        if authentication.accountState != .connected {
            Button(tr("Accedi a \(authentication.selectedSite.platformName)", "Sign in to \(authentication.selectedSite.platformName)")) { open(.settings) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        } else if authentication.isSyncActive {
            Button(tr("Annulla", "Cancel")) { authentication.cancelSynchronization() }
                .controlSize(.large)
                .keyboardShortcut(".", modifiers: .command)
        } else {
            Button { authentication.synchronizeNow() } label: {
                Label(tr("Sincronizza ora", "Sync now"), systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("r", modifiers: .command)
            .help(authentication.enabledCourseIDs.isEmpty ? tr("Attiva almeno un corso", "Enable at least one course") : tr("Sincronizza ora (⌘R)", "Sync now (⌘R)"))
            .disabled(!authentication.canSynchronize)
        }
    }

    // The cadence, readable at a glance and changeable in place. Independent from the sync
    // button, so it stays usable when a sync isn't possible (no course enabled, loading…).
    private var automaticMenu: some View {
        Menu {
            Picker(tr("Controllo automatico", "Automatic check"), selection: automaticMode) {
                Text(tr("Solo manuale", "Manual only")).tag(0)
                ForEach(AutomaticSyncOption.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(automaticCaption)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .disabled(authentication.isSyncActive)
        .help(tr("Frequenza del controllo automatico in background", "How often to check automatically in the background"))
    }

    private var automaticCaption: String {
        guard authentication.automaticSyncEnabled else { return tr("Controllo automatico disattivato", "Automatic check off") }
        let option = AutomaticSyncOption(rawValue: authentication.automaticSyncInterval)
        return tr("Controllo automatico: ", "Automatic check: ") + (option?.title.lowercased() ?? tr("attivo", "on"))
    }

    private var conflictsBanner: some View {
        Button { open(.conflicts) } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(conflictsBannerText)
                    .font(.callout)
                Spacer(minLength: 0)
                Text(tr("Risolvi", "Resolve")).font(.callout.weight(.medium)).foregroundStyle(.tint)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // The .conflicts headline already states the count; the banner then only says what to do.
    private var conflictsBannerText: String {
        if case .conflicts = state { return tr("Scegli quale versione tenere per ogni file.", "Choose which version to keep for each file.") }
        let count = authentication.conflicts.count
        if count == 0 {
            let changes = authentication.remoteChanges.count
            let platform = authentication.selectedSite.platformName
            return changes == 1 ? tr("1 file spostato o rimosso su \(platform) aspetta una tua scelta.", "1 file moved or removed on \(platform) needs your choice.") : tr("\(changes) file spostati o rimossi su \(platform) aspettano una tua scelta.", "\(changes) files moved or removed on \(platform) need your choice.")
        }
        return count == 1 ? tr("1 file ha due versioni: scegli quale tenere.", "1 file has two versions: choose which to keep.") : tr("\(count) file hanno due versioni: scegli quali tenere.", "\(count) files have two versions: choose which to keep.")
    }

    private var automaticMode: Binding<Int> {
        Binding(
            get: { authentication.automaticSyncEnabled ? authentication.automaticSyncInterval : 0 },
            set: { interval in
                authentication.setAutomaticSync(enabled: interval != 0, interval: interval == 0 ? nil : interval)
            }
        )
    }
}

/// The only view observing `SyncProgressStore`, so progress ticks re-render this line and
/// nothing else.
private struct SyncProgressLine: View {
    @ObservedObject var progressStore: SyncProgressStore

    var body: some View {
        let progress = progressStore.progress
        VStack(alignment: .leading, spacing: 6) {
            if progress.total > 0 {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(WeBeepAuthenticationController.progressDetail(progress) ?? tr("Preparazione…", "Preparing…"))
                Spacer()
                if progress.installed > 0 {
                    Text(progress.installed == 1 ? tr("1 materiale scaricato", "1 material downloaded") : tr("\(progress.installed) materiali scaricati", "\(progress.installed) materials downloaded"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }
}

// MARK: - Course row

private struct CourseRow: View {
    let course: RemoteCourseSummary
    let folder: String
    let isEnabled: Bool
    let isRenaming: Bool
    let renameError: String?
    let toggleDisabled: Bool
    let renameDisabled: Bool
    let organizeDisabled: Bool
    let folderURL: URL?
    /// Used for actions only; the row redraws from the plain values above.
    let authentication: WeBeepAuthenticationController
    /// Owned by the list so only one row is ever in rename mode.
    let isEditing: Bool
    let setEditing: (Bool) -> Void
    let organize: () -> Void

    @State private var proposedFolder = ""
    @State private var isHovered = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            SymbolTile(systemImage: "folder.fill", tint: isEnabled ? .accentColor : .gray, size: 32, filled: isEnabled)
            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    renameField
                } else {
                    Text(folder)
                        .font(.body.weight(.medium))
                        .foregroundStyle(isEnabled ? .primary : .secondary)
                        .lineLimit(1)
                }
                Text(course.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let renameError {
                    Text(renameError).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isRenaming {
                ProgressView().controlSize(.small)
            }
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovered || isEditing ? 1 : 0.35)
            .accessibilityLabel(tr("Azioni per \(course.displayName)", "Actions for \(course.displayName)"))
            Toggle(tr("Sincronizza \(course.displayName)", "Sync \(course.displayName)"), isOn: Binding(
                get: { isEnabled },
                set: { authentication.setCourse(course, enabled: $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(toggleDisabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isHovered ? Color.primary.opacity(0.035) : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu { menuItems }
        .disabled(isRenaming)
    }

    // Menu actions only touch view-local @State or call into the controller the same way the
    // previous buttons did; nothing here bridges AppKit callbacks into the main actor.
    @ViewBuilder private var menuItems: some View {
        Button(tr("Rinomina cartella…", "Rename folder…"), systemImage: "pencil") { beginRename() }
            .disabled(renameDisabled)
        Button(tr("Organizza cartelle…", "Organize folders…"), systemImage: "folder.badge.gearshape") { organize() }
            .disabled(organizeDisabled)
        Divider()
        Button(tr("Mostra nel Finder", "Show in Finder"), systemImage: "folder") {
            if let folderURL { Finder.reveal(folderURL) }
        }
        .disabled(folderURL == nil)
    }

    private var renameField: some View {
        HStack(spacing: 6) {
            TextField(tr("Nome cartella locale", "Local folder name"), text: $proposedFolder)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onAppear { fieldFocused = true }
                .onSubmit { commitRename() }
                .onExitCommand { cancelRename() }
                .onChange(of: proposedFolder) { authentication.clearRenameError(for: course) }
            Button(tr("Conferma", "Confirm"), systemImage: "checkmark.circle.fill") { commitRename() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .disabled(proposedFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(tr("Annulla", "Cancel"), systemImage: "xmark.circle.fill") { cancelRename() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
    }

    private func beginRename() {
        authentication.clearRenameError(for: course)
        proposedFolder = folder
        setEditing(true)
    }

    private func cancelRename() {
        authentication.clearRenameError(for: course)
        setEditing(false)
    }

    private func commitRename() {
        let newFolder = proposedFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newFolder.isEmpty else { return }
        let current = folder.precomposedStringWithCanonicalMapping
        guard newFolder.precomposedStringWithCanonicalMapping.localizedCaseInsensitiveCompare(current) != .orderedSame else {
            cancelRename()
            return
        }
        authentication.renameFolder(for: course, to: newFolder)
        setEditing(false)
    }
}
