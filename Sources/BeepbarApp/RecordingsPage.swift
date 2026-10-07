import SwiftUI
import BeepbarCore

/// The rules of what the Recordings page shows, kept out of the views so tests can pin them.
enum RecordingsPresentation {
    static func syncedCourses(_ courses: [RemoteCourseSummary], enabledIDs: Set<Int64>) -> [RemoteCourseSummary] {
        courses.filter { enabledIDs.contains($0.id) }
    }

    static func selectedCourse(_ courses: [RemoteCourseSummary], selectedID: Int64?) -> RemoteCourseSummary? {
        courses.first { $0.id == selectedID }
            ?? courses.first { RecmanCourseKey(course: $0) != nil }
            ?? courses.first
    }

    struct WeekSection: Equatable {
        let title: String
        let recordings: [RecmanRecording]
    }

    /// Weeks start on Monday, as Polimi's timetable does, whatever the Mac's region says.
    static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.timeZone = timeZone
        return calendar
    }

    /// The minutes in Recman's duration ("97 min"); the parser accepts no other shape.
    static func minutes(_ duration: String) -> Int? {
        Int(duration.prefix { $0.isNumber })
    }

    /// "45 min", "1 h 37 min", "36 h".
    static func durationText(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// Newest first, grouped by calendar week: "Questa settimana", "Settimana scorsa", then the
    /// week's dates ("14 – 20 set"), with the year only when it isn't the current one.
    static func weekSections(_ recordings: [RecmanRecording], now: Date, calendar: Calendar, locale: Locale) -> [WeekSection] {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek)
        var sections: [(start: Date, recordings: [RecmanRecording])] = []
        for recording in recordings.sorted(by: { $0.recordedAt > $1.recordedAt }) {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: recording.recordedAt)?.start else { continue }
            if sections.last?.start == start {
                sections[sections.count - 1].recordings.append(recording)
            } else {
                sections.append((start, [recording]))
            }
        }
        return sections.map { section in
            let title: String
            if section.start == thisWeek {
                title = tr("Questa settimana", "This week")
            } else if section.start == lastWeek {
                title = tr("Settimana scorsa", "Last week")
            } else {
                title = weekRange(from: section.start, now: now, calendar: calendar, locale: locale)
            }
            return WeekSection(title: title, recordings: section.recordings)
        }
    }

    static func weekRange(from start: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
        var style = Date.FormatStyle(timeZone: calendar.timeZone).day().month(.abbreviated).locale(locale)
        if calendar.component(.year, from: end) != calendar.component(.year, from: now) { style = style.year() }
        let sameMonth = calendar.component(.month, from: start) == calendar.component(.month, from: end)
        let startText = sameMonth ? Date.FormatStyle(timeZone: calendar.timeZone).day().locale(locale).format(start) : style.format(start)
        return "\(startText) – \(style.format(end))"
    }

    /// Each recording's place in its course, oldest first, as students count lessons ("#12").
    static func numbers(_ recordings: [RecmanRecording]) -> [String: Int] {
        let ordered = recordings.sorted { ($0.recordedAt, $0.id) < ($1.recordedAt, $1.id) }
        return Dictionary(ordered.enumerated().map { ($0.element.id, $0.offset + 1) }, uniquingKeysWith: { first, _ in first })
    }

    /// What a row is called: Recman's title, or the kind of lesson when the teacher left it empty.
    static func title(_ recording: RecmanRecording) -> String {
        recording.title.isEmpty ? recording.kind : recording.title
    }

    static func matches(_ recording: RecmanRecording, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return recording.title.localizedStandardContains(needle) || recording.kind.localizedStandardContains(needle)
    }
}

/// Registrazioni: the synced courses on the left, the chosen course's recordings on the right,
/// grouped by week, newest first. A double click, Return or the play button opens the Webex
/// player in the default browser.
///
/// The page drives `RecordingsController`'s lifetime: it reports appearing and disappearing, and
/// asks for its courses; the controller decides what actually needs a request.
struct RecordingsPage: View {
    @ObservedObject var authentication: WeBeepAuthenticationController
    @ObservedObject var recordings: RecordingsController
    @State private var selectedCourseID: Int64?

    private var courses: [RemoteCourseSummary] {
        RecordingsPresentation.syncedCourses(authentication.courses, enabledIDs: authentication.enabledCourseIDs)
    }

    private var searchableCourses: [(course: RemoteCourseSummary, key: RecmanCourseKey)] {
        courses.compactMap { course in RecmanCourseKey(course: course).map { (course, $0) } }
    }

    private var unsearchableCourses: [RemoteCourseSummary] {
        courses.filter { RecmanCourseKey(course: $0) == nil }
    }

    private var keys: [RecmanCourseKey] { searchableCourses.map(\.key) }

    private var selectedCourse: RemoteCourseSummary? {
        RecordingsPresentation.selectedCourse(courses, selectedID: selectedCourseID)
    }

    var body: some View {
        Group {
            switch recordings.access {
            case .ready: browser
            case .signingIn, .needsSignIn, .off: signIn
            }
        }
        .onAppear {
            recordings.pageAppeared()
            refresh()
        }
        .onDisappear { recordings.pageDisappeared() }
        .onChange(of: keys) { refresh() }
        .onChange(of: selectedCourseID) { refresh() }
    }

    private func refresh(force: Bool = false) {
        recordings.refresh(keys, selected: selectedCourse.flatMap(RecmanCourseKey.init(course:)), force: force)
    }

    // MARK: Sign-in

    private var signIn: some View {
        VStack(spacing: 14) {
            SymbolTile(systemImage: "play.rectangle.fill", size: 52)
            Text(tr("Registrazioni delle lezioni", "Lecture recordings"))
                .font(.title3.weight(.semibold))
            Text(tr("Trova le registrazioni dei corsi che sincronizzi, cerca una lezione e riproducila nel browser. Accedi con Polimi per iniziare. Se non ti serve questa funzione, disattiva Registrazioni in Impostazioni.",
                    "Find recordings for the courses you sync, search for a lecture and play it in your browser. Sign in with Polimi to get started. If you don't need this feature, turn off Recordings in Settings."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            if case .needsSignIn(let problem?) = recordings.access {
                NoticeBanner(text: problem.message, systemImage: "wifi.exclamationmark", tint: .orange)
                    .frame(maxWidth: 420)
            }
            if recordings.access == .signingIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("Accesso in corso… Se si apre la finestra del Politecnico, completa l'accesso lì.", "Signing in… If Polimi's window opens, finish signing in there."))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            } else {
                Button(tr("Accedi con Polimi", "Sign in with Polimi")) { recordings.signIn() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(BeepbarStyle.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Two panes

    @ViewBuilder private var browser: some View {
        if courses.isEmpty {
            ContentUnavailableView {
                Label(tr("Nessun corso sincronizzato", "No synced courses"), systemImage: "books.vertical")
            } description: {
                Text(tr("Scegli i corsi da sincronizzare in Corsi: qui trovi le loro registrazioni.", "Choose the courses to sync in Courses: their recordings show up here."))
            }
        } else {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 230)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { selectedCourse?.id }, set: { selectedCourseID = $0 })) {
            Section(tr("I tuoi corsi", "Your courses")) {
                ForEach(searchableCourses, id: \.course.id) { entry in
                    CourseRow(name: authentication.folder(for: entry.course), listing: recordings.listing(for: entry.key), newCount: recordings.newCount(for: entry.key))
                        .tag(entry.course.id)
                }
            }
            if !unsearchableCourses.isEmpty {
                Section(tr("Senza codice o anno", "No code or year")) {
                    ForEach(unsearchableCourses) { course in
                        Text(authentication.folder(for: course))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                            .tag(course.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.quaternary.opacity(0.35))
    }

    @ViewBuilder private var detail: some View {
        if let course = selectedCourse {
            if let key = RecmanCourseKey(course: course) {
                CourseRecordings(name: authentication.folder(for: course), key: key, recordings: recordings) {
                    refresh(force: true)
                }
                .id(course.id)
            } else {
                ContentUnavailableView {
                    Label(authentication.folder(for: course), systemImage: "questionmark.folder")
                } description: {
                    Text(tr("Il nome del corso su WeBeep non riporta codice e anno accademico, quindi BeepBar non sa quali registrazioni cercare.",
                            "The course's name on WeBeep doesn't carry its code and academic year, so BeepBar can't tell which recordings to look for."))
                }
            }
        }
    }
}

/// A course in the sidebar: its folder name, how many recordings it has, and the new ones.
private struct CourseRow: View {
    let name: String
    let listing: RecordingsListing?
    let newCount: Int

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if newCount > 0 {
                Text(newCount, format: .number)
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 17)
                    .background(Color.accentColor, in: Capsule())
                    .accessibilityLabel(tr("\(newCount) nuove", "\(newCount) new"))
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if let count = listing?.recordings?.count {
            return count == 0 ? tr("Nessuna registrazione", "No recordings") : tr("\(count) registrazioni", englishCount(count, "recording", "recordings"))
        }
        if listing?.isLoading == true { return tr("Caricamento…", "Loading…") }
        if listing?.problem != nil { return tr("Non disponibile", "Unavailable") }
        return " "
    }
}

/// The right pane: one course's recordings, searchable, grouped by week.
private struct CourseRecordings: View {
    let name: String
    let key: RecmanCourseKey
    @ObservedObject var recordings: RecordingsController
    let refresh: () -> Void
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var searchFocused: Bool

    private var listing: RecordingsListing? { recordings.listing(for: key) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let problem = listing?.problem {
                NoticeBanner(text: problem.message, systemImage: "wifi.exclamationmark", tint: .orange)
                    .padding([.horizontal, .top], 14)
            }
            if let problem = recordings.openingProblem {
                NoticeBanner(text: problem.message, systemImage: "play.slash", tint: .orange)
                    .padding([.horizontal, .top], 14)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if recordings.newCount(for: key) > 0 {
                Button(tr("Segna come viste", "Mark as seen")) { recordings.markSeen(key) }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
            if (listing?.recordings?.count ?? 0) > 6 || !query.isEmpty { searchField }
            Button(action: refresh) {
                ZStack {
                    ProgressView().controlSize(.small).opacity(listing?.isLoading == true ? 1 : 0)
                    Image(systemName: "arrow.clockwise").opacity(listing?.isLoading == true ? 0 : 1)
                }
                .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(listing?.isLoading == true)
            .help(tr("Aggiorna le registrazioni", "Refresh the recordings"))
            .accessibilityLabel(tr("Aggiorna registrazioni", "Refresh recordings"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summary: String {
        let year = key.academicYearLabel
        guard let list = listing?.recordings else {
            return listing?.isLoading == true ? "\(year) · \(tr("caricamento…", "loading…"))" : year
        }
        let minutes = list.compactMap { RecordingsPresentation.minutes($0.duration) }.reduce(0, +)
        var parts = [year, tr("\(list.count) registrazioni", englishCount(list.count, "recording", "recordings"))]
        if minutes > 0 { parts.append(RecordingsPresentation.durationText(minutes: minutes)) }
        if let updatedAt = listing?.updatedAt { parts.append(tr("aggiornato \(updatedAt.relativeText)", "updated \(updatedAt.relativeText)")) }
        return parts.joined(separator: " · ")
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(tr("Cerca lezioni", "Search lessons"), text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand {
                    if query.isEmpty { searchFocused = false } else { query = "" }
                }
            if !query.isEmpty {
                Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(tr("Cancella ricerca", "Clear search"))
            }
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(width: 170)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
    }

    @ViewBuilder private var content: some View {
        if let list = listing?.recordings {
            let shown = list.filter { RecordingsPresentation.matches($0, query: query) }
            if list.isEmpty {
                ContentUnavailableView {
                    Label(tr("Ancora nessuna registrazione", "No recordings yet"), systemImage: "video.slash")
                } description: {
                    Text(tr("Quando ne viene pubblicata una, la trovi qui.", "When one is published, you'll find it here."))
                }
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                recordingList(shown, numbers: RecordingsPresentation.numbers(list))
            }
        } else if listing?.isLoading == true {
            VStack(spacing: 10) {
                ProgressView()
                Text(tr("Cerco le registrazioni nell'archivio del Politecnico…", "Looking for recordings in Polimi's archive…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func recordingList(_ shown: [RecmanRecording], numbers: [String: Int]) -> some View {
        let sections = RecordingsPresentation.weekSections(shown, now: Date(), calendar: RecordingsPresentation.calendar(), locale: BeepbarStyle.locale)
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return List(selection: $selection) {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.recordings) { recording in
                        RecordingRow(
                            recording: recording,
                            number: numbers[recording.id],
                            isNew: recordings.isNew(recording),
                            isOpening: recordings.openingRecordingID == recording.id,
                            play: { recordings.play(recording) }
                        )
                        .tag(recording.id)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        // Double click and Return open the player, the way Finder opens a file.
        .contextMenu(forSelectionType: String.self) { ids in
            if let recording = ids.first.flatMap({ byID[$0] }) {
                Button(tr("Apri nel browser", "Open in browser")) { recordings.play(recording) }
                Button(tr("Copia link", "Copy link")) { recordings.copyLink(recording) }
            }
        } primaryAction: { ids in
            if let recording = ids.first.flatMap({ byID[$0] }) { recordings.play(recording) }
        }
    }
}

/// One recording: unseen dot, lesson number, title, when and how long, its kind, and a play
/// button that shows on hover (and while the player is being looked up).
private struct RecordingRow: View {
    let recording: RecmanRecording
    let number: Int?
    let isNew: Bool
    let isOpening: Bool
    let play: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isNew ? Color.accentColor : .clear)
                .frame(width: 7, height: 7)
                .accessibilityLabel(isNew ? tr("Nuova", "New") : "")
            Text(number.map { "#\($0)" } ?? "")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(RecordingsPresentation.title(recording))
                    .fontWeight(isNew ? .semibold : .regular)
                    .lineLimit(1)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !recording.title.isEmpty, !recording.kind.isEmpty {
                CountPill(text: recording.kind)
            }
            Button(action: play) {
                ZStack {
                    ProgressView().controlSize(.small).opacity(isOpening ? 1 : 0)
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .opacity(isOpening ? 0 : 1)
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .opacity(isHovered || isOpening ? 1 : 0)
            .help(tr("Apri nel browser", "Open in browser"))
            .accessibilityLabel(tr("Riproduci \(RecordingsPresentation.title(recording))", "Play \(RecordingsPresentation.title(recording))"))
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var details: String {
        let when = recording.recordedAt.formatted(Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(BeepbarStyle.locale))
        let length = RecordingsPresentation.minutes(recording.duration).map { RecordingsPresentation.durationText(minutes: $0) } ?? recording.duration
        return "\(when) · \(length)"
    }
}
