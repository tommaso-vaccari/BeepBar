import SwiftUI
import BeepbarCore

/// The rules of what the Recordings page shows, kept out of the views so tests can pin them.
/// The list rules live in Core (`RecmanPresentation`, `RecmanCourseSidebar`), where the page's
/// cached derivations use them (#100); these forward to them, so the page and its tests can never
/// disagree with what the cache derives.
enum RecordingsPresentation {
    typealias WeekSection = RecmanPresentation.WeekSection

    static func syncedCourses(_ courses: [RemoteCourseSummary], enabledIDs: Set<Int64>) -> [RemoteCourseSummary] {
        RecmanCourseSidebar(.init(courses: courses, enabledIDs: enabledIDs)).courses
    }

    static func selectedCourse(_ courses: [RemoteCourseSummary], selectedID: Int64?) -> RemoteCourseSummary? {
        RecmanCourseSidebar(.init(courses: courses, enabledIDs: Set(courses.map(\.id)))).selectedCourse(id: selectedID)
    }

    /// Hide recognized archive identifiers without changing the course's wording or acronyms.
    static func courseName(_ course: RemoteCourseSummary) -> String {
        RecmanCourseSidebar.courseName(course)
    }

    /// Weeks start on Monday, as Polimi's timetable does, whatever the Mac's region says.
    static func calendar(timeZone: TimeZone = .current) -> Calendar {
        RecmanPresentation.calendar(timeZone: timeZone)
    }

    /// The minutes in Recman's duration ("97 min"); the parser accepts no other shape. Delegates to
    /// Core so the row, the course header and the hours-left estimate read the same number.
    static func minutes(_ duration: String) -> Int? {
        RecmanRecording.minutes(inDuration: duration)
    }

    static func durationText(minutes: Int) -> String { RecmanPresentation.durationText(minutes: minutes) }

    static func weekSections(_ recordings: [RecmanRecording], now: Date, calendar: Calendar, locale: Locale) -> [WeekSection] {
        RecmanPresentation.weekSections(recordings, now: now, calendar: calendar, locale: locale)
    }

    static func weekRange(from start: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        RecmanPresentation.weekRange(from: start, now: now, calendar: calendar, locale: locale)
    }

    static func numbers(_ recordings: [RecmanRecording]) -> [String: Int] { RecmanPresentation.numbers(recordings) }

    static func title(_ recording: RecmanRecording) -> String { RecmanPresentation.title(recording) }

    static func matches(_ recording: RecmanRecording, query: String) -> Bool { RecmanPresentation.matches(recording, query: query) }

    /// The sidebar row's title: the course name, or the renamed local folder plus the teacher.
    /// See `RecmanCourseSidebar.sidebarName`.
    static func sidebarName(courseName: String, courseDisplayName: String, courseID: Int64 = 0, localFolderName: String?) -> String {
        RecmanCourseSidebar.sidebarName(courseName: courseName, courseDisplayName: courseDisplayName, courseID: courseID, localFolderName: localFolderName)
    }

    /// Whether the sidebar row shows the orange "lectures to watch" marker: only for a known
    /// summary of a course with recordings that are not all done. An unknown summary (nil: the
    /// listing was never loaded, another account) claims nothing; a course with none (0/0) or all
    /// done shows nothing (`done < total` is false for both). `next` is not used: it is nil for old saved data that still has counts.
    static func hasLecturesToWatch(summary: CourseWatchSummary?) -> Bool {
        guard let summary else { return false }
        return summary.done < summary.total
    }

    /// VoiceOver's label of that marker.
    static let lecturesToWatchLabel = BilingualText("Lezioni da guardare", "Lectures to watch")

    /// VoiceOver's value of that marker: how many lectures are left.
    static func lecturesToWatchValue(_ summary: CourseWatchSummary) -> BilingualText {
        let left = max(0, summary.total - summary.done)
        return BilingualText("\(left) da guardare", "\(left) left")
    }

    // MARK: Watch progress

    /// What one row shows of its watch progress, as plain values: the row compares it with `==`,
    /// so a ~30 s tick of the playing lecture (`RecordingsWatchProgressModel.live`) runs the body
    /// of that lecture's row only, never every row (principle 6).
    ///
    /// `known == false` means the store's state is not loaded for this recording (a Watchlist row
    /// offline, signed out or still loading): the store may well say "done", so the row shows no
    /// bar and no checkbox rather than claiming 0 % or "not done". All other fields are zero then,
    /// so changes the row can't show don't re-render it either.
    struct WatchRow: Equatable, Sendable {
        /// The stored state of this recording is known (see `RecordingsWatchProgressModel.known`).
        let known: Bool
        /// Furthest point reached, in 0...1, live session included.
        let fraction: Double
        let completed: Bool
        /// A tick or un-tick of this recording is being saved.
        let pending: Bool
        /// The student can tick lectures now (`RecordingsController.canEditProgress`).
        let canEdit: Bool

        static let unknown = WatchRow(known: false, fraction: 0, completed: false, pending: false, canEdit: false)

        // The row's view reads only the fields below (never `known`, `completed` or `pending`
        // directly), so every visible decision is pinned by `RecordingRowProgressTests`.

        /// The checkbox is ticked: the committed state only, never the value being saved, so a
        /// failed save can't leave a box that lies (no optimistic flip while `pending`).
        var isOn: Bool { completed }

        /// The checkbox is drawn: only when the stored state is known. An empty box for an
        /// unknown row would say "not done" for a lecture the store may say is done. Hidden rows
        /// keep their slot (opacity), so the layout doesn't jump when the listing loads.
        var checkboxVisible: Bool { known }

        /// The checkbox is hidden from VoiceOver, for the same reason it is hidden on screen.
        var checkboxAccessibilityHidden: Bool { !known }

        /// The checkbox accepts a click: known, editable, and no save of it in flight.
        var checkboxEnabled: Bool { known && canEdit && !pending }

        /// The bar's value, nil when there is no bar (unknown state). Full once done, whatever the
        /// furthest point: ticking a lecture attended in person completes it at 0 %.
        var barValue: Double? {
            guard known else { return nil }
            return completed ? 1 : Self.clamped(fraction)
        }

        /// The "done" styling: green bar and a check mark after it.
        var showsDoneStyle: Bool { known && completed }

        /// The bar's colour: green once done, the accent colour otherwise.
        var barTint: Color { showsDoneStyle ? .green : .accentColor }

        /// The whole percent shown for a lecture that is not done: rounded down and never above
        /// 99, so the row never claims 100 % before the lecture is done (a lecture played to the
        /// very end but still open, or un-ticked after being watched, reads 99 %). Rounding down
        /// also keeps 0.4 % from reading as 1 %. The tiny epsilon absorbs binary representation
        /// error before flooring: 0.29 × 100 is 28.999999999999996 in `Double` and must read 29.
        var percent: Int { min(99, Int((Self.clamped(fraction) * 100 + 1e-9).rounded(.down))) }

        /// VoiceOver's value for the bar: "Fatta"/"Done" once done, otherwise "N% visto"/"N%
        /// watched". Both languages, so tests can check each without switching the app language.
        var accessibilityValue: BilingualText {
            completed ? BilingualText("Fatta", "Done") : BilingualText("\(percent)% visto", "\(percent)% watched")
        }

        private static func clamped(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
    }

    /// A copy of what `RecordingsWatchProgressModel` publishes, taken once per update by
    /// `WatchProgressReader` and handed to the list as a value.
    ///
    /// Why a value and not the model: a `List`'s rows are built lazily, outside the reader's body,
    /// and SwiftUI rebuilds them only when the row-building closure's captured values change. With
    /// the model captured (a reference that never changes) a tick re-ran the reader and left every
    /// row as it was, bar included; with these values captured, the closure changes with the model.
    /// The dictionaries are copy-on-write, so taking the copy costs nothing per row. Deliberately
    /// not `Equatable`: comparing it would walk every entry.
    struct WatchValues {
        let entries: [String: RecordingWatchEntry]
        let live: [String: Double]
        let pending: Set<String>
        let known: Set<String>
        /// Each loaded course's summary, live position included: the course header's line.
        let summaries: [RecmanCourseKey: CourseWatchSummary]
        /// `RecordingsController.canEditProgress` when the reader was built (see
        /// `WatchProgressReader.init` on why a stale value is harmless).
        let canEdit: Bool

        @MainActor init(_ model: RecordingsWatchProgressModel, canEdit: Bool) {
            entries = model.entries
            live = model.live
            pending = model.pending
            known = model.known
            summaries = model.summaries
            self.canEdit = canEdit
        }

        /// The row values of `recording`: `.unknown` when its stored state isn't known, whatever
        /// is in memory for it; otherwise the rules of `RecordingsWatchProgressModel`'s accessors
        /// (`fraction(for:)`: the further of stored and live).
        func row(for recording: RecmanRecording) -> WatchRow {
            let identity = RecordingsStudyState.identity(recording)
            guard known.contains(identity) else { return .unknown }
            let entry = entries[identity] ?? .untouched
            return WatchRow(known: true, fraction: max(entry.furthest, live[identity] ?? 0), completed: entry.isCompleted,
                            pending: pending.contains(identity), canEdit: canEdit)
        }

        /// The course header's summary line: `base` ("2026/27 · 30 registrazioni · 36 h"), then
        /// the progress line of `key` when there is one (`watchSummaryText`).
        func headerLine(_ base: String, for key: RecmanCourseKey) -> String {
            guard let watched = RecordingsPresentation.watchSummaryText(summaries[key]) else { return base }
            return "\(base) · \(watched.text)"
        }
    }

    /// The course header's progress line, "12/30 fatte · ~14 h rimanenti" / "12/30 done · ~14 h
    /// left", or nil when there is nothing to say: the summary is unknown (listing not loaded,
    /// account unknown) or the course has no recordings, which never reads "0/0". The time left
    /// comes from Core (`remainingTimeText`) so it rounds exactly like the menu bar; it is left
    /// out when nothing is left to watch.
    static func watchSummaryText(_ summary: CourseWatchSummary?) -> BilingualText? {
        guard let summary, summary.total > 0 else { return nil }
        let count = "\(summary.done)/\(summary.total)"
        guard let left = RecordingWatchProgress.remainingTimeText(minutes: summary.remainingMinutes), summary.done < summary.total else {
            return BilingualText("\(count) fatte", "\(count) done")
        }
        return BilingualText("\(count) fatte · \(left) rimanenti", "\(count) done · \(left) left")
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
    /// The sidebar derived from the synced courses (#100). The page observes every publication of
    /// both controllers (a spinner, a row opening, a bookmark), and each archive key costs two
    /// regular expressions per course name and each display name two more: they are worked out
    /// again only when the course list or the courses chosen for syncing change. The course shown
    /// on the right is not part of the key: picking it is a lookup in the result. A cache, not
    /// view state: filling it during `body` changes nothing SwiftUI observes.
    @State private var sidebarCache = DerivedValueCache<RecmanCourseSidebar.Inputs, RecmanCourseSidebar>()

    /// Every use in one `body` after the first is an equality check of the inputs. For arrays the
    /// controllers republish unchanged it is a storage comparison; equal content in new storage
    /// is compared once, after which the cache holds the new array.
    private var model: RecmanCourseSidebar {
        sidebarCache.value(for: .init(courses: authentication.courses, enabledIDs: authentication.enabledCourseIDs, folders: authentication.courseFolders), compute: RecmanCourseSidebar.init)
    }

    private var keys: [RecmanCourseKey] { model.keys }

    private var selectedCourseID: Int64? {
        if case .course(let id) = recordings.study.destination { return id }
        return nil
    }

    private var destination: RecordingsDestination {
        if recordings.study.destination == .watchlist { return .watchlist }
        return selectedCourse.map { .course($0.id) } ?? .watchlist
    }

    private var selectedCourse: RemoteCourseSummary? {
        model.selectedCourse(id: selectedCourseID)
    }

    /// The selected course's archive entry, nil when its name carries no code and year.
    private var selectedEntry: RecmanCourseSidebar.Entry? {
        guard let selectedCourse else { return nil }
        return model.searchable.first { $0.course.id == selectedCourse.id }
    }

    var body: some View {
        Group {
            switch recordings.access {
            case .ready: browser
            case .signingIn, .needsSignIn:
                if !recordings.study.bookmarks.isEmpty { browser } else { signIn }
            case .off: signIn
            }
        }
        .onAppear {
            recordings.pageAppeared()
            refresh()
        }
        .onDisappear { recordings.pageDisappeared() }
        .onChange(of: keys) { refresh() }
        .onChange(of: destination) { refresh() }
        .onChange(of: recordings.study.bookmarks.map(\.id)) { refresh() }
    }

    private func refresh(force: Bool = false) {
        let savedKeys = recordings.study.bookmarks.compactMap { RecmanCourseKey(courseCode: $0.recording.courseCode, academicYear: $0.recording.academicYear) }
        let requested = destination == .watchlist ? Array(Set(keys + savedKeys)).sorted { ($0.academicYear, $0.courseCode) < ($1.academicYear, $1.courseCode) } : keys
        recordings.refresh(requested, selected: destination == .watchlist ? nil : selectedEntry?.key, force: force)
    }

    // MARK: Sign-in

    private var signIn: some View {
        VStack(spacing: 14) {
            if let problem = recordings.studyProblem {
                NoticeBanner(text: problem.text, systemImage: "exclamationmark.triangle", tint: .orange)
                    .frame(maxWidth: 420)
            }
            SymbolTile(systemImage: "play.rectangle.fill", size: 52)
            Text(tr("Registrazioni delle lezioni", "Lecture recordings"))
                .font(.title3.weight(.semibold))
            Text(tr("Trova le registrazioni dei corsi che sincronizzi, cerca una lezione e riproducila in BeepBar. Accedi con Polimi per iniziare. Se non ti serve questa funzione, disattiva Registrazioni in Impostazioni.",
                    "Find recordings for the courses you sync, search for a lecture and play it in BeepBar. Sign in with Polimi to get started. If you don't need this feature, turn off Recordings in Settings."))
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

    private var browser: some View {
        VStack(spacing: 0) {
            if recordings.access != .ready {
                HStack(spacing: 10) {
                    Text(tr("La watchlist è salvata. Accedi con Polimi per riprodurre e aggiornare le lezioni.", "Your watchlist is saved. Sign in with Polimi to play and refresh lessons."))
                        .font(.callout)
                    Spacer()
                    if recordings.access == .signingIn { ProgressView().controlSize(.small) }
                    else { Button(tr("Accedi con Polimi", "Sign in with Polimi")) { recordings.signIn() } }
                }
                .padding(14)
                if case .needsSignIn(let problem?) = recordings.access {
                    NoticeBanner(text: problem.message, systemImage: "wifi.exclamationmark", tint: .orange)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }
                Divider()
            }
            if let problem = recordings.studyProblem {
                NoticeBanner(text: problem.text, systemImage: "exclamationmark.triangle", tint: .orange)
                    .padding(14)
            }
            HStack(spacing: 0) {
                sidebar.frame(width: 230)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var sidebar: some View {
        List(selection: Binding<RecordingsDestination?>(get: { destination }, set: { if let value = $0 { recordings.selectDestination(value) } })) {
            Section {
                HStack {
                    Label(tr("Watchlist", "Watchlist"), systemImage: "bookmark")
                    Spacer()
                    Text(recordings.study.bookmarks.count, format: .number)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .tag(RecordingsDestination.watchlist)
            }
            Section(tr("I tuoi corsi", "Your courses")) {
                // The reader re-runs the closure when the saved summaries move (a checkpoint, a tick
                // box, a listing): `refreshWatchSummary` sets the window's summary just before it
                // saves the committed one. The marker reads the committed `watchSummaries`, so
                // a ~30 s tick changes no value; `CourseRow` is `Equatable` on plain values and
                // its body does not run for it.
                WatchProgressReader(recordings: recordings) { _ in
                    ForEach(model.searchable) { entry in
                        let summary = recordings.watchSummaries[entry.key]
                        CourseRow(name: entry.sidebarName, key: entry.key, subtitle: CourseRow.subtitle(for: recordings.listing(for: entry.key)), newCount: recordings.newCount(for: entry.key),
                                  toWatch: RecordingsPresentation.hasLecturesToWatch(summary: summary) ? summary.map(RecordingsPresentation.lecturesToWatchValue) : nil)
                            .equatable()
                            .tag(RecordingsDestination.course(entry.course.id))
                    }
                }
            }
            if !model.unsearchable.isEmpty {
                Section(tr("Senza codice o anno", "No code or year")) {
                    ForEach(model.unsearchable) { entry in
                        Text(entry.sidebarName)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.secondary)
                            .tag(RecordingsDestination.course(entry.course.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(.quaternary.opacity(0.35))
    }

    @ViewBuilder private var detail: some View {
        if destination == .watchlist {
            WatchlistRecordings(recordings: recordings) { refresh(force: true) }
        } else if let course = selectedCourse {
            if let entry = selectedEntry {
                CourseRecordings(name: entry.name, key: entry.key, recordings: recordings) {
                    refresh(force: true)
                }
                .id(course.id)
            } else {
                ContentUnavailableView {
                    Label(model.unsearchable.first { $0.course.id == course.id }?.name ?? RecordingsPresentation.courseName(course), systemImage: "questionmark.folder")
                } description: {
                    Text(tr("Il nome del corso su WeBeep non riporta codice e anno accademico, quindi BeepBar non sa quali registrazioni cercare.",
                            "The course's name on WeBeep doesn't carry its code and academic year, so BeepBar can't tell which recordings to look for."))
                }
            }
        }
    }
}

/// A course in the sidebar keeps its code and year visible to distinguish matching names.
///
/// `Equatable` on plain values on purpose (see `WatchProgressReader`): the sidebar sits inside a
/// reader that runs on every progress publication, and equal values skip this body.
private struct CourseRow: View, Equatable {
    let name: String
    let key: RecmanCourseKey
    let subtitle: String
    let newCount: Int
    /// Non-nil (the lectures left, as VoiceOver's value) when the orange marker shows.
    let toWatch: BilingualText?

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(key.courseCode) · \(key.academicYearLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // The marker sits before the "new" badge in the same trailing stack: both can show,
            // side by side, without overlapping. Orange is not the accent colour of the badge.
            if let toWatch {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                    .help(RecordingsPresentation.lecturesToWatchLabel.text)
                    .accessibilityElement()
                    .accessibilityLabel(RecordingsPresentation.lecturesToWatchLabel.text)
                    .accessibilityValue(toWatch.text)
            }
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

    static func subtitle(for listing: RecordingsListing?) -> String {
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
    /// The pane's rows and week sections (#100). The pane observes the whole controller, so its
    /// `body` runs again when a spinner flips, a row starts opening or another course's listing
    /// arrives; the search and the grouping by week (a calendar lookup per recording) are redone
    /// only when the listing, the search, the language, the time zone or the day changes.
    /// `RecmanCourseListDerivation.Inputs` says why each is there.
    @State private var derivation = DerivedValueCache<RecmanCourseListDerivation.Inputs, RecmanCourseListDerivation>()
    /// Lesson numbers and total minutes, which depend on the listing alone: typing in the search
    /// doesn't sort the whole list again.
    @State private var summaryCache = DerivedValueCache<[RecmanRecording], RecmanCourseListSummary>()

    private var listing: RecordingsListing? { recordings.listing(for: key) }

    private func derivedList(_ list: [RecmanRecording]) -> RecmanCourseListDerivation {
        derivation.value(for: .init(recordings: list, query: query, language: AppLanguage.current, timeZone: .current, now: Date()), compute: RecmanCourseListDerivation.init)
    }

    private func summary(_ list: [RecmanRecording]) -> RecmanCourseListSummary {
        summaryCache.value(for: list, compute: RecmanCourseListSummary.init)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
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
        // `summary` sums the listing's minutes: computed here, where a progress tick doesn't
        // reach, and only joined with the progress line inside the reader.
        let summary = summary
        return VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.title3.weight(.semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            WatchProgressReader(recordings: recordings) { progress in
                let line = progress.headerLine(summary, for: key)
                #if DEBUG
                let _ = RecordingsPageProbes.header?(line)
                #endif
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let updatedAt = listing?.updatedAt {
                Text(tr("Aggiornato \(updatedAt.relativeText)", "Updated \(updatedAt.relativeText)"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            searchField
            Spacer(minLength: 0)
            if recordings.newCount(for: key) > 0 {
                Button(tr("Segna novità come lette", "Mark new recordings as read")) { recordings.markSeen(key) }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .fixedSize()
            }
            Button(action: refresh) {
                ZStack {
                    ProgressView().controlSize(.small).opacity(listing?.isLoading == true ? 1 : 0)
                    Image(systemName: "arrow.clockwise").opacity(listing?.isLoading == true ? 0 : 1)
                }
                .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .disabled(listing?.isLoading == true)
            .help(tr("Aggiorna le registrazioni", "Refresh the recordings"))
            .accessibilityLabel(tr("Aggiorna registrazioni", "Refresh recordings"))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    private var summary: String {
        let year = key.academicYearLabel
        guard let list = listing?.recordings else {
            return listing?.isLoading == true ? "\(year) · \(tr("caricamento…", "loading…"))" : year
        }
        let minutes = summary(list).totalMinutes
        var parts = [year, tr("\(list.count) registrazioni", englishCount(list.count, "recording", "recordings"))]
        if minutes > 0 { parts.append(RecordingsPresentation.durationText(minutes: minutes)) }
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
        .padding(.vertical, 7)
        .frame(minWidth: 120, maxWidth: 280)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5))
    }

    @ViewBuilder private var content: some View {
        if let list = listing?.recordings {
            let model = derivedList(list)
            if list.isEmpty {
                ContentUnavailableView {
                    Label(tr("Ancora nessuna registrazione", "No recordings yet"), systemImage: "video.slash")
                } description: {
                    Text(tr("Quando ne viene pubblicata una, la trovi qui.", "When one is published, you'll find it here."))
                }
            } else if model.shown.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                recordingList(model, numbers: summary(list).numbers)
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

    private func recordingList(_ model: RecmanCourseListDerivation, numbers: [String: Int]) -> some View {
        let byID = model.byID
        let firstID = model.shown.first?.id
        // One set per `body` instead of a scan of every bookmark for every row.
        let watchlisted = Set(recordings.study.bookmarks.map(\.id))
        // Sections, filtering and numbering stay here (this view doesn't observe the progress
        // model); a tick re-runs only the reader's closure below, see `WatchProgressReader`.
        return WatchProgressReader(recordings: recordings) { progress in
            List(selection: $selection) {
                ForEach(model.sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.recordings) { recording in
                            RecordingRow(
                                recording: recording,
                                number: numbers[recording.id],
                                isNew: recordings.isNew(recording),
                                isOpening: recordings.openingRecordingID == recording.id,
                                isWatchlisted: watchlisted.contains(RecordingsStudyState.identity(recording)),
                                canEdit: recordings.canEditStudy,
                                canPlay: recordings.access == .ready,
                                watchlistCourseName: name,
                                watch: progress.row(for: recording),
                                actions: RecordingRow.Actions(
                                    toggleWatchlist: { recordings.toggleWatchlist(recording, courseName: name) },
                                    play: { recordings.play(recording) },
                                    setDone: { recordings.setDone(recording, $0) }
                                )
                            )
                            .equatable()
                            .uiContentReady(.recordings, enabled: recording.id == firstID)
                            .tag(recording.id)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        // Double click and Return open the player, the way Finder opens a file.
        .contextMenu(forSelectionType: String.self) { ids in
            if let recording = ids.first.flatMap({ byID[$0] }) {
                // Really the browser: Play (double click, Return, the row's button) is BeepBar's
                // own player since #148, and this item is the way around it.
                Button(tr("Apri nel browser", "Open in browser")) { recordings.openInBrowser(recording) }
                Button(tr("Copia link", "Copy link")) { recordings.copyLink(recording) }
                Button(recordings.study.contains(recording) ? tr("Rimuovi dalla watchlist", "Remove from watchlist") : tr("Aggiungi alla watchlist", "Add to watchlist")) { recordings.toggleWatchlist(recording, courseName: name) }
                    .disabled(!recordings.canEditStudy)
            }
        } primaryAction: { ids in
            if let recording = ids.first.flatMap({ byID[$0] }) { recordings.play(recording) }
        }
    }
}

/// The global queue uses saved snapshots, so choosing what to watch never requires visiting each course.
private struct WatchlistRecordings: View {
    @ObservedObject var recordings: RecordingsController
    let refresh: () -> Void
    @State private var query = ""
    @State private var selection: String?
    /// The bookmarks matching the search, newest first (#100): filtered and sorted again only when
    /// the bookmarks or the search change, not on every publication of the controller.
    @State private var shownCache = DerivedValueCache<ShownInputs, [RecordingsStudyState.Bookmark]>()

    private struct ShownInputs: Equatable {
        let bookmarks: [RecordingsStudyState.Bookmark]
        let query: String
    }

    private var shown: [RecordingsStudyState.Bookmark] {
        let study = recordings.study
        return shownCache.value(for: ShownInputs(bookmarks: study.bookmarks, query: query)) { study.visibleBookmarks(query: $0.query) }
    }

    private var listings: [RecordingsListing] {
        let keys = Set(recordings.study.bookmarks.compactMap {
            RecmanCourseKey(courseCode: $0.recording.courseCode, academicYear: $0.recording.academicYear)
        })
        return keys.sorted { ($0.academicYear, $0.courseCode) < ($1.academicYear, $1.courseCode) }
            .compactMap { recordings.listing(for: $0) }
    }

    // `listings` looks up every bookmarked course, and depends on listings the controller updates
    // all the time: worked out once per `body` and passed down, not once per use (#100).
    var body: some View {
        let shown = self.shown
        let listings = self.listings
        let isLoading = listings.contains { $0.isLoading }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Watchlist", "Watchlist")).font(.title3.weight(.semibold))
                Text(tr("Le lezioni che hai scelto, da tutti i corsi.", "The lessons you chose, from every course."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
            HStack(spacing: 12) {
                TextField(tr("Cerca lezioni o corsi", "Search lessons or courses"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, maxWidth: 280)
                Spacer(minLength: 0)
                Button(action: refresh) {
                    ZStack {
                        Image(systemName: "arrow.clockwise").opacity(isLoading ? 0 : 1)
                        if isLoading { ProgressView().controlSize(.small) }
                    }
                }
                    .buttonStyle(.borderless)
                    .help(tr("Aggiorna la watchlist", "Refresh watchlist"))
                    .accessibilityLabel(tr("Aggiorna la watchlist", "Refresh watchlist"))
                    .disabled(recordings.access != .ready || isLoading)
            }
            .padding(.horizontal, 20).padding(.bottom, 14)
            Divider()
            if let problem = listings.compactMap(\.problem).first {
                NoticeBanner(text: problem.message, systemImage: "wifi.exclamationmark", tint: .orange).padding(14)
            }
            if let problem = recordings.openingProblem {
                NoticeBanner(text: problem.message, systemImage: "play.slash", tint: .orange).padding(14)
            }
            if shown.isEmpty { empty.frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                // Same split as the course list: only the reader observes the progress model.
                // A bookmark whose course listing isn't loaded is unknown to the model and shows
                // neither bar nor checkbox (`RecordingsPresentation.WatchRow.unknown`).
                WatchProgressReader(recordings: recordings) { progress in
                    List(selection: $selection) {
                        ForEach(shown) { bookmark in
                            let item = bookmark.recording
                            RecordingRow(recording: item, number: nil, isNew: recordings.isNew(item),
                                isOpening: recordings.openingRecordingID == item.id,
                                isWatchlisted: true,
                                canEdit: recordings.canEditStudy, canPlay: recordings.access == .ready && !bookmark.unavailable,
                                courseName: bookmark.courseName, unavailable: bookmark.unavailable,
                                watchlistCourseName: bookmark.courseName,
                                watch: progress.row(for: item),
                                actions: RecordingRow.Actions(
                                    toggleWatchlist: { recordings.toggleWatchlist(item, courseName: bookmark.courseName) },
                                    play: { recordings.play(item) },
                                    setDone: { recordings.setDone(item, $0) }
                                ))
                                .equatable()
                                .tag(bookmark.id)
                        }
                    }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let bookmark = shown.first(where: { ids.contains($0.id) }) {
                        Button(tr("Rimuovi dalla watchlist", "Remove from watchlist")) { recordings.toggleWatchlist(bookmark.recording, courseName: bookmark.courseName) }
                            .disabled(!recordings.canEditStudy)
                        Button(tr("Apri nel browser", "Open in browser")) { recordings.openInBrowser(bookmark.recording) }
                            .disabled(recordings.access != .ready || bookmark.unavailable)
                    }
                } primaryAction: { ids in
                    if let bookmark = shown.first(where: { ids.contains($0.id) }), !bookmark.unavailable {
                        recordings.play(bookmark.recording)
                    }
                }
            }
        }
    }

    @ViewBuilder private var empty: some View {
        if recordings.study.bookmarks.isEmpty {
            ContentUnavailableView {
                Label(tr("La watchlist è vuota", "Your watchlist is empty"), systemImage: "bookmark")
            } description: {
                Text(tr("Scegli un corso e usa il segnalibro accanto a una lezione per aggiungerla qui.", "Choose a course and bookmark a lesson to add it here."))
            }
        } else {
            ContentUnavailableView.search(text: query)
        }
    }
}

/// Observes the watch progress model once for a whole list (or header) and hands its content a
/// copy of the model's values (`RecordingsPresentation.WatchValues`) to build plain row values
/// from.
///
/// Why: a playing lecture's ~30 s tick re-renders every view observing the model. The parent
/// pages observe only the controller and build the list's data (filtering, week sections,
/// numbers) in their own body, which a tick never reaches; the tick re-runs only this reader's
/// closure, `List` builds the visible rows again (the content must capture the values, see
/// `WatchValues`), and `RecordingRow` being `Equatable` keeps SwiftUI from running the body of
/// any row whose values didn't change: in practice the playing lecture's row. Never observe the
/// model in a row (one subscription per row, every row's body on each tick) or in the pages
/// themselves (sections recomputed on each tick).
///
/// Cost per tick, measured on the isolated fixture at 5eb7199 (a temporary counter in
/// `WatchValues.row`, `aTickReRendersOnlyThePlayingRow`, 1000×700 window): 302 `row` calls with
/// 1,000 recordings and 326 with 5,000 (the rows `List` keeps built around the visible ones,
/// nearly flat in the listing's size), and one row body in both. Package G records these numbers
/// with the rest of the delivery evidence.
struct WatchProgressReader<Content: View>: View {
    @ObservedObject var progress: RecordingsWatchProgressModel
    /// `RecordingsController.canEditProgress` when the page built this reader. It can go stale
    /// until the page's next update (it isn't published), and that is harmless: `setDone`
    /// checks the account again and does nothing without one, and the checkbox draws only the
    /// committed value, so a click that was refused leaves the box as it was.
    let canEdit: Bool
    @ViewBuilder let content: (RecordingsPresentation.WatchValues) -> Content

    init(recordings: RecordingsController, @ViewBuilder content: @escaping (RecordingsPresentation.WatchValues) -> Content) {
        progress = recordings.watchProgress
        canEdit = recordings.canEditProgress
        self.content = content
    }

    /// What the content receives; a property so tests can read it without rendering.
    var values: RecordingsPresentation.WatchValues { RecordingsPresentation.WatchValues(progress, canEdit: canEdit) }

    var body: some View { content(values) }
}

#if DEBUG
/// Test seams of the Recordings page, nil (no cost beyond the check) outside tests: each row
/// body hands over the row it draws, and the course header the line it shows, so a hosting test
/// can prove what reached the screen and how often.
@MainActor enum RecordingsPageProbes {
    static var row: ((RecordingRow) -> Void)?
    static var header: ((String) -> Void)?
}
#endif

/// A recording keeps its title above its metadata and its play action visible without hover.
///
/// `Equatable` on purpose (see `WatchProgressReader`): `==` compares every value the body shows
/// and ignores `actions`. Invariant: the actions capture only the controller (one per page),
/// `recording` and `watchlistCourseName`, all compared or constant, so a row skipped as equal
/// can never hold an action aimed at another recording or course name. Add any new captured
/// value as a compared field.
struct RecordingRow: View, Equatable {
    /// What the row's controls do. Closures, so the row needs no controller and tests can host it.
    struct Actions {
        let toggleWatchlist: () -> Void
        let play: () -> Void
        /// Ticks (true) or un-ticks the lecture: `RecordingsController.setDone`.
        let setDone: (Bool) -> Void
    }

    let recording: RecmanRecording
    let number: Int?
    let isNew: Bool
    let isOpening: Bool
    let isWatchlisted: Bool
    let canEdit: Bool
    let canPlay: Bool
    var courseName: String? = nil
    var unavailable = false
    /// The course name a bookmark made from this row stores (the page's name in a course list,
    /// the bookmark's own in the Watchlist). Captured by `actions.toggleWatchlist`.
    let watchlistCourseName: String
    let watch: RecordingsPresentation.WatchRow
    let actions: Actions

    nonisolated static func == (lhs: RecordingRow, rhs: RecordingRow) -> Bool {
        lhs.recording == rhs.recording && lhs.number == rhs.number && lhs.isNew == rhs.isNew
            && lhs.isOpening == rhs.isOpening && lhs.isWatchlisted == rhs.isWatchlisted
            && lhs.canEdit == rhs.canEdit && lhs.canPlay == rhs.canPlay && lhs.courseName == rhs.courseName
            && lhs.unavailable == rhs.unavailable && lhs.watchlistCourseName == rhs.watchlistCourseName
            && lhs.watch == rhs.watch
    }

    /// The checkbox's binding: reads the committed value only (`WatchRow.isOn`, no optimistic
    /// flip) and forwards exactly the value the student asked for.
    static func doneBinding(watch: RecordingsPresentation.WatchRow, setDone: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { watch.isOn }, set: { setDone($0) })
    }

    var body: some View {
        #if DEBUG
        let _ = RecordingsPageProbes.row?(self)
        #endif
        HStack(spacing: 10) {
            Circle()
                .fill(isNew ? Color.accentColor : .clear)
                .frame(width: 7, height: 7)
                .accessibilityLabel(isNew ? tr("Nuova", "New") : "")
            if let number {
                Text("#\(number)")
                    .font(.callout).monospacedDigit().foregroundStyle(.tertiary)
                    .frame(width: 34, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let courseName {
                    Text(courseName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(RecordingsPresentation.title(recording))
                    .font(.body.weight(isNew ? .semibold : .medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        metadata.fixedSize()
                        kind.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        metadata
                        kind
                    }
                }
                if unavailable {
                    Text(tr("Non più disponibile nell’archivio", "No longer available in the archive"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                progressBar
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            doneCheckbox
            Button(action: actions.toggleWatchlist) {
                Image(systemName: isWatchlisted ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 20))
                    .foregroundStyle(isWatchlisted ? Color.accentColor : .secondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain).disabled(!canEdit)
            .help(isWatchlisted ? tr("Rimuovi dalla watchlist", "Remove from watchlist") : tr("Aggiungi alla watchlist", "Add to watchlist"))
            .accessibilityLabel(isWatchlisted ? tr("Rimuovi dalla watchlist", "Remove from watchlist") : tr("Aggiungi alla watchlist", "Add to watchlist"))
            Button(action: actions.play) {
                ZStack {
                    ProgressView().controlSize(.small).opacity(isOpening ? 1 : 0)
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .opacity(isOpening ? 0 : 1)
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(!canPlay)
            // Play is BeepBar's own player since #148 (the browser only when that isn't possible);
            // "Apri nel browser" is the row menu's item.
            .help(tr("Riproduci", "Play"))
            .accessibilityLabel(tr("Riproduci \(RecordingsPresentation.title(recording))", "Play \(RecordingsPresentation.title(recording))"))
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    /// A thin read-only bar under the metadata: how far the student got, full and green once
    /// done. Absent while the stored state is unknown, so the row never claims 0 % for a lecture
    /// the store may say is done.
    @ViewBuilder private var progressBar: some View {
        if let value = watch.barValue {
            HStack(spacing: 6) {
                ProgressView(value: value)
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .tint(watch.barTint)
                    .frame(maxWidth: 220)
                if watch.showsDoneStyle {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr("Avanzamento", "Progress"))
            .accessibilityValue(watch.accessibilityValue.text)
        }
    }

    /// "Done (watched or attended in person)". Shows the committed value only: a click asks the
    /// controller, and the box flips when the saved value is published (disabled meanwhile), so
    /// a failed save never leaves a box that lies. While the state is unknown the box keeps its
    /// place but is hidden: an empty box would say "not done" for a lecture that may be done.
    private var doneCheckbox: some View {
        let label = tr("Fatta (vista o seguita in presenza)", "Done (watched or attended in person)")
        return Toggle(label, isOn: Self.doneBinding(watch: watch, setDone: actions.setDone))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!watch.checkboxEnabled)
            .opacity(watch.checkboxVisible ? 1 : 0)
            .accessibilityHidden(watch.checkboxAccessibilityHidden)
            .help(label)
    }

    private var metadata: some View {
        Text(details)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var kind: some View {
        if !recording.title.isEmpty, !recording.kind.isEmpty {
            CountPill(text: recording.kind)
        }
    }

    private var details: String {
        var style = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(BeepbarStyle.locale)
        if Calendar.current.component(.year, from: recording.recordedAt) != Calendar.current.component(.year, from: Date()) {
            style = style.year()
        }
        let when = recording.recordedAt.formatted(style)
        let length = RecordingsPresentation.minutes(recording.duration).map { RecordingsPresentation.durationText(minutes: $0) } ?? recording.duration
        return "\(when) · \(length)"
    }
}
