import SwiftUI
import BeepbarCore

/// The window's tabs. The raw value is only the declaration order: it is never stored, and the
/// ⌘-number shortcuts follow the visible tabs (`visiblePages`), not this value.
enum ShellPage: Int, CaseIterable, Identifiable {
    case home, activity, conflicts, recordings, settings

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: tr("Corsi", "Courses")
        case .activity: tr("Attività", "Activity")
        case .conflicts: tr("Conflitti", "Conflicts")
        case .recordings: tr("Registrazioni", "Recordings")
        case .settings: tr("Impostazioni", "Settings")
        }
    }

    var systemImage: String {
        switch self {
        case .home: "books.vertical"
        case .activity: "clock.arrow.circlepath"
        case .conflicts: "exclamationmark.triangle"
        case .recordings: "play.rectangle"
        case .settings: "gearshape"
        }
    }

    /// The tabs in the bar, in order: Registrazioni only while the feature is on (Polimi only).
    static func visiblePages(showsRecordings: Bool) -> [ShellPage] {
        allCases.filter { $0 != .recordings || showsRecordings }
    }

    /// The page actually shown: a hidden tab (Recordings just turned off, or a stale route)
    /// falls back to Corsi instead of an empty window.
    static func shown(_ page: ShellPage, showsRecordings: Bool) -> ShellPage {
        visiblePages(showsRecordings: showsRecordings).contains(page) ? page : .home
    }
}

/// Lets the window controller route the shell to a page (e.g. "Apri conflitti" from the menu
/// bar) without the SwiftUI tree having to exist beforehand.
@MainActor final class ShellRouter: ObservableObject {
    @Published var page: ShellPage = .home
}

struct BeepbarShellView: View {
    @ObservedObject var authentication: WeBeepAuthenticationController
    @ObservedObject var recordings: RecordingsController
    @ObservedObject var router: ShellRouter
    @Namespace private var tabSelection

    // Strings are resolved when a body runs, and rows that take plain values wouldn't rerun on
    // their own, so a language change rebuilds the whole tree. The page lives in the router, so
    // Settings stays open across the switch.
    var body: some View {
        page
            .id(authentication.language)
            .environment(\.locale, authentication.language.locale)
    }

    @ViewBuilder private var page: some View {
        if authentication.needsOnboarding {
            OnboardingView(authentication: authentication)
                .frame(minWidth: 680, minHeight: 500)
        } else {
            VStack(spacing: 0) {
                header
                Divider()
                content
                    .id(shownPage)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .ignoresSafeArea(.container, edges: .top)
            .frame(minWidth: 680, minHeight: 500)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var showsRecordings: Bool { recordings.isEnabled }

    private var shownPage: ShellPage { ShellPage.shown(router.page, showsRecordings: showsRecordings) }

    @ViewBuilder private var content: some View {
        switch shownPage {
        case .home: HomePage(authentication: authentication, open: open)
        case .activity: ActivityPage(authentication: authentication)
        case .conflicts: ConflictsPage(authentication: authentication)
        case .recordings: RecordingsPage(authentication: authentication, recordings: recordings)
        case .settings: SettingsPage(authentication: authentication)
        }
    }

    // Drawn into the (transparent) title bar: the traffic lights sit on the left, the page
    // switcher is centered, mirroring a unified toolbar.
    private var header: some View {
        tabBar
            .frame(maxWidth: .infinity)
            .padding(.leading, 72)
            .padding(.trailing, 12)
            .frame(height: 52)
            .background(.bar)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            let pages = ShellPage.visiblePages(showsRecordings: showsRecordings)
            ForEach(Array(pages.enumerated()), id: \.element) { index, page in
                tabButton(page, shortcut: index + 1)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.7), in: Capsule())
    }

    private func tabButton(_ page: ShellPage, shortcut: Int) -> some View {
        let isSelected = shownPage == page
        return Button { open(page) } label: {
            HStack(spacing: 5) {
                Image(systemName: page.systemImage)
                    .symbolVariant(isSelected ? .fill : .none)
                Text(page.title)
                if page == .conflicts, !authentication.conflicts.isEmpty || !authentication.remoteChanges.isEmpty {
                    Text(authentication.conflicts.count + authentication.remoteChanges.count, format: .number)
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(.red, in: Capsule())
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.14), radius: 1.5, y: 0.5)
                        .matchedGeometryEffect(id: "selectedTab", in: tabSelection)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        // By position, so the shortcuts stay ⌘1…⌘n with no gap whichever tabs are shown.
        .keyboardShortcut(KeyEquivalent(Character(String(shortcut))), modifiers: .command)
        .help("\(page.title) (⌘\(shortcut))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(BeepbarStyle.snappy, value: authentication.conflicts.count)
    }

    private func open(_ page: ShellPage) {
        if page == .conflicts { authentication.refreshConflicts() }
        withAnimation(BeepbarStyle.snappy) { router.page = page }
    }
}
