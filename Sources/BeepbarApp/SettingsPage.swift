import SwiftUI
import BeepbarCore

struct SettingsPage: View {
    @ObservedObject var authentication: WeBeepAuthenticationController
    // Sparkle's setting isn't observable; mirror it so the toggle reflects changes immediately.
    @State private var checksForUpdates = UpdaterController.shared.automaticallyChecksForUpdates
    @State private var showSignOutConfirmation = false
    @ObservedObject private var launchAtLogin = LaunchAtLoginController.shared

    var body: some View {
        Form {
            languageSection
            accountSection
            folderSection
            startupSection
            automaticSection
            notificationsSection
            updatesSection
        }
        .formStyle(.grouped)
        // On the Form, not on the startup Section: modifiers on a Section inside a Form can be
        // applied to each of its rows, which would start one refresh per row.
        .task {
            await launchAtLogin.refresh()
            await authentication.refreshNotificationAuthorization()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await launchAtLogin.refresh()
                await authentication.refreshNotificationAuthorization()
            }
        }
        .confirmationDialog(tr("Disconnettere l'account \(authentication.selectedSite.platformName)?", "Disconnect the \(authentication.selectedSite.platformName) account?"), isPresented: $showSignOutConfirmation, titleVisibility: .visible) {
            Button(tr("Disconnetti", "Disconnect"), role: .destructive) { authentication.signOut() }
            Button(tr("Annulla", "Cancel"), role: .cancel) {}
        } message: {
            Text(tr("Il token salvato viene eliminato da questo Mac. La cartella dei materiali e i file restano dove sono.", "The saved token is removed from this Mac. The materials folder and files stay where they are."))
        }
    }

    // MARK: Language

    private var languageSection: some View {
        Section {
            LanguagePicker(authentication: authentication)
        } header: {
            Text(tr("Lingua", "Language"))
        }
    }

    // MARK: Account

    private var accountSection: some View {
        Section {
            if !authentication.hasStoredCredential {
                MoodleSitePicker(authentication: authentication)
            }
            HStack(spacing: 12) {
                SymbolTile(systemImage: accountSymbol, tint: accountTint, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(authentication.accountState.title).font(.body.weight(.medium))
                    Text(authentication.selectedSite.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if authentication.isVerifying || authentication.isAuthenticating {
                    ProgressView().controlSize(.small)
                }
                Button(tr("Verifica", "Verify")) { authentication.validateConnection() }
                    .disabled(!authentication.hasStoredCredential || authentication.isVerifying)
                if authentication.hasStoredCredential {
                    Button(tr("Disconnetti…", "Disconnect…")) { showSignOutConfirmation = true }
                        .disabled(authentication.isSyncActive || authentication.isLoadingCourses)
                }
                if authentication.accountState != .connected {
                    Button(authentication.accountState == .expired ? tr("Accedi di nuovo", "Sign in again") : tr("Accedi", "Sign in")) { authentication.startLogin() }
                        .buttonStyle(.borderedProminent)
                        .disabled(authentication.isAuthenticating)
                }
            }
        } header: {
            Text(tr("Account \(authentication.selectedSite.platformName)", "\(authentication.selectedSite.platformName) account"))
        } footer: {
            Label(tr("Il token resta in locale, protetto da permessi ristretti.", "The token stays on this Mac, protected by restricted permissions."), systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var accountSymbol: String {
        switch authentication.accountState {
        case .connected: "person.crop.circle.badge.checkmark"
        case .expired: "person.crop.circle.badge.exclamationmark"
        case .notConnected: "person.crop.circle.badge.plus"
        }
    }

    private var accountTint: Color {
        switch authentication.accountState {
        case .connected: .green
        case .expired: .orange
        case .notConnected: .gray
        }
    }

    // MARK: Folder

    private var folderSection: some View {
        Section {
            HStack(spacing: 12) {
                SymbolTile(systemImage: "folder.fill", tint: .blue, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(authentication.rootURL?.lastPathComponent ?? tr("Nessuna cartella scelta", "No folder chosen"))
                        .font(.body.weight(.medium))
                    if let rootURL = authentication.rootURL {
                        Text((rootURL.path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                if let rootURL = authentication.rootURL {
                    Button(tr("Mostra nel Finder", "Show in Finder")) { Finder.reveal(rootURL) }
                }
                Button(authentication.rootURL == nil ? tr("Scegli cartella…", "Choose folder…") : tr("Cambia…", "Change…")) { authentication.chooseRoot() }
            }
        } header: {
            Text(tr("Cartella dei materiali", "Materials folder"))
        } footer: {
            Text(tr("Ogni corso abilitato viene salvato direttamente qui, nella propria cartella.", "Each enabled course is saved right here, in its own folder."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Startup

    /// "Apri BeepBar al login". The switch shows macOS's real status, re-read whenever Settings
    /// appears or BeepBar becomes active (see the Form's `.task`), because the user can also
    /// change it in System Settings.
    private var startupSection: some View {
        Section {
            Toggle(tr("Apri BeepBar al login", "Open BeepBar at login"), isOn: Binding(
                get: { launchAtLogin.isOn },
                set: { enabled in Task { await launchAtLogin.setEnabled(enabled) } }
            ))
            .disabled(!launchAtLogin.canChange)
        } header: {
            Text(tr("Avvio", "Startup"))
        } footer: {
            startupFooter
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var startupFooter: some View {
        if let error = launchAtLogin.errorMessage {
            Text(error.text)
        } else if launchAtLogin.location != .applications && !launchAtLogin.isOn {
            Text(tr("Sposta BeepBar nella cartella Applicazioni per aprirla al login.", "Move BeepBar to the Applications folder to open it at login."))
        } else if launchAtLogin.status == .requiresApproval {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("È disattivata in Impostazioni di Sistema, dove puoi riattivarla.", "It's turned off in System Settings, where you can turn it back on."))
                Button(tr("Apri Impostazioni di Sistema…", "Open System Settings…")) { launchAtLogin.openSystemSettings() }
                    .buttonStyle(.link)
            }
        } else {
            Text(tr("Quando è attiva, BeepBar si apre da sola all'accesso al Mac, così la sincronizzazione automatica riprende anche dopo un riavvio.", "When it's on, BeepBar opens by itself when you log in to your Mac, so automatic sync resumes after a restart too."))
        }
    }

    // MARK: Background

    private var automaticSection: some View {
        Section {
            Toggle(tr("Sincronizzazione automatica", "Automatic sync"), isOn: Binding(
                get: { authentication.automaticSyncEnabled },
                set: { authentication.setAutomaticSync(enabled: $0) }
            ))
            Picker(tr("Frequenza", "Frequency"), selection: Binding(
                get: { authentication.automaticSyncInterval },
                set: { authentication.setAutomaticSyncInterval($0) }
            )) {
                ForEach(AutomaticSyncOption.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .disabled(!authentication.automaticSyncEnabled)
        } header: {
            Text(tr("Attività in background", "Background activity"))
        } footer: {
            Text(tr("Tutti i corsi selezionati vengono controllati. Conflitti e modifiche locali non vengono mai sovrascritti automaticamente.", "All selected courses are checked. Conflicts and local changes are never overwritten automatically."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Notifications

    /// "Notifiche" (#64). The switch is BeepBar's own; macOS's permission is separate and can only
    /// be changed in System Settings, so when macOS blocks them the footer says so and links there.
    private var notificationsSection: some View {
        Section {
            Toggle(tr("Notifiche", "Notifications"), isOn: Binding(
                get: { authentication.notificationsEnabled },
                set: { enabled in Task { await authentication.setNotifications(enabled: enabled) } }
            ))
        } header: {
            Text(tr("Notifiche", "Notifications"))
        } footer: {
            notificationsFooter
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var notificationsFooter: some View {
        if authentication.notificationsEnabled && authentication.notificationAuthorization == .denied {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("macOS blocca le notifiche di BeepBar. Puoi consentirle in Impostazioni di Sistema.", "macOS is blocking BeepBar's notifications. You can allow them in System Settings."))
                Button(tr("Apri Impostazioni di Sistema…", "Open System Settings…")) { Self.openNotificationSettings() }
                    .buttonStyle(.link)
            }
        } else {
            Text(tr("Nuovi materiali, conflitti da risolvere e problemi di sincronizzazione. Con le notifiche spente, l'icona e le pagine di BeepBar restano aggiornate.", "New materials, conflicts to resolve and sync problems. With notifications off, BeepBar's icon and pages stay up to date."))
        }
    }

    /// BeepBar's own page in System Settings → Notifications.
    private static func openNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "io.github.tvaccari.beepbar"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Updates

    private var updatesSection: some View {
        Section(tr("Aggiornamenti", "Updates")) {
            Toggle(tr("Controlla automaticamente gli aggiornamenti", "Check for updates automatically"), isOn: $checksForUpdates)
                .onChange(of: checksForUpdates) { _, newValue in
                    UpdaterController.shared.automaticallyChecksForUpdates = newValue
                }
            LabeledContent(tr("Versione", "Version")) {
                HStack(spacing: 10) {
                    Text(appVersion).foregroundStyle(.secondary).monospacedDigit()
                    Button(tr("Cerca aggiornamenti…", "Check for updates…")) { UpdaterController.shared.checkForUpdates() }
                }
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return tr("Sviluppo", "Development") }
        if let build = info?["CFBundleVersion"] as? String { return "\(version) (\(build))" }
        return version
    }
}
