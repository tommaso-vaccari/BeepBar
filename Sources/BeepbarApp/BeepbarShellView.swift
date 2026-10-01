import SwiftUI
import BeepbarCore

enum ShellPage: Int, CaseIterable, Identifiable {
    case home, activity, conflicts, settings

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: tr("Corsi", "Courses")
        case .activity: tr("Attività", "Activity")
        case .conflicts: tr("Conflitti", "Conflicts")
        case .settings: tr("Impostazioni", "Settings")
        }
    }

    var systemImage: String {
        switch self {
        case .home: "books.vertical"
        case .activity: "clock.arrow.circlepath"
        case .conflicts: "exclamationmark.triangle"
        case .settings: "gearshape"
        }
    }
}

/// Lets the window controller route the shell to a page (e.g. "Apri conflitti" from the menu
/// bar) without the SwiftUI tree having to exist beforehand.
@MainActor final class ShellRouter: ObservableObject {
    @Published var page: ShellPage = .home
}

struct BeepbarShellView: View {
    @ObservedObject var authentication: WeBeepAuthenticationController
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
                    .id(router.page)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .ignoresSafeArea(.container, edges: .top)
            .frame(minWidth: 680, minHeight: 500)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    @ViewBuilder private var content: some View {
        switch router.page {
        case .home: HomePage(authentication: authentication, open: open)
        case .activity: ActivityPage(authentication: authentication)
        case .conflicts: ConflictsPage(authentication: authentication)
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
            ForEach(ShellPage.allCases) { page in
                tabButton(page)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.7), in: Capsule())
    }

    private func tabButton(_ page: ShellPage) -> some View {
        let isSelected = router.page == page
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
        .keyboardShortcut(KeyEquivalent(Character(String(page.rawValue + 1))), modifiers: .command)
        .help("\(page.title) (⌘\(page.rawValue + 1))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(BeepbarStyle.snappy, value: authentication.conflicts.count)
    }

    private func open(_ page: ShellPage) {
        if page == .conflicts { authentication.refreshConflicts() }
        withAnimation(BeepbarStyle.snappy) { router.page = page }
    }
}
