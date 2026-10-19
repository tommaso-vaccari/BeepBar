import SwiftUI
import BeepbarCore

struct SettingsPage: View {
    @ObservedObject var authentication: WeBeepAuthenticationController
    // Sparkle's setting isn't observable; mirror it so the toggle reflects changes immediately.
    @State private var checksForUpdates = UpdaterController.shared.automaticallyChecksForUpdates
    @State private var showSignOutConfirmation = false
    @State private var showPrivacy = false
    @ObservedObject private var launchAtLogin = LaunchAtLoginController.shared

    @ObservedObject private var telemetry = DailyTelemetryController.shared

    var body: some View {
        Form {
            languageSection
            accountSection
            folderSection
            if authentication.selectedSite.university == .polimi {
                RecordingsSettingsSection(recordings: authentication.recordings)
            }
            startupSection
            automaticSection
            notificationsSection
            updatesSection
            telemetrySection
            privacySection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPrivacy) { privacyDetails }
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
            Text(tr("Il token salvato viene eliminato da questo Mac. La cartella dei materiali, il database di sincronizzazione e le scelte di studio salvate restano sul Mac.", "The saved token is removed from this Mac. The materials folder, sync database and saved study choices remain on this Mac."))
        }
    }

    private var telemetrySection: some View {
        Section(tr("Telemetria", "Telemetry")) {
            Toggle(isOn: Binding(
                get: { telemetry.isEnabled },
                set: { telemetry.setEnabled($0) }
            )) {
                SettingLabel(tr("Telemetria", "Telemetry"), explanation: tr("Attiva di default. Invia a TelemetryDeck al massimo un segnale al giorno: versione dell’app e versione principale di macOS, con un identificativo condiviso da tutte le installazioni e il primo invio mensile contato separatamente. Non invia lingua, impostazioni, account, corsi o file. Il server riceve anche l’indirizzo IP della connessione. Spegnendola si interrompono gli invii futuri e si eliminano gli identificativi delle vecchie versioni; i segnali già inviati non vengono cancellati.", "Enabled by default. Sends TelemetryDeck at most one signal a day: app version and major macOS version, with one identifier shared by every installation and the first monthly report counted separately. Language, settings, accounts, courses and files are not sent. The server also receives the connection IP address. Turning it off stops future sends and removes identifiers from older versions; previously sent signals are not deleted."))
            }
            .disabled(!telemetry.isConfigured)
        }
    }

    private var privacySection: some View {
        Section(tr("Dati e privacy", "Data and privacy")) {
            Button(tr("Dati salvati e collegamenti esterni…", "Saved data and external connections…")) { showPrivacy = true }
            Link(tr("Contatta per la privacy", "Privacy contact"), destination: URL(string: "mailto:tommaso.vaccari@mail.polimi.it")!)
            if let recordings = authentication.recordingsForPrivacy {
                SessionDeletionWarning(recordings: recordings)
            }
        }
    }

    private var privacyDetails: some View {
        PrivacyNoticeView()
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
                    .disabled(authentication.isAuthenticating || authentication.isVerifying)
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
                    .disabled(!authentication.hasStoredCredential || authentication.isVerifying || authentication.isAuthenticating)
                if authentication.hasStoredCredential {
                    Button(tr("Disconnetti…", "Disconnect…")) { showSignOutConfirmation = true }
                        .disabled(authentication.isSyncActive || authentication.isLoadingCourses || authentication.isVerifying || authentication.isAuthenticating)
                }
                if authentication.accountState != .connected {
                    Button(authentication.accountState == .expired ? tr("Accedi di nuovo", "Sign in again") : tr("Accedi", "Sign in")) { authentication.startLogin() }
                        .buttonStyle(.borderedProminent)
                        .disabled(authentication.isAuthenticating || authentication.isVerifying)
                }
            }
            if let feedback = authentication.authenticationFeedback {
                Text(feedback.text)
                    .font(.callout)
                    .foregroundStyle(.orange)
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
            Toggle(isOn: Binding(
                get: { launchAtLogin.isOn },
                set: { enabled in Task { await launchAtLogin.setEnabled(enabled) } }
            )) {
                SettingLabel(tr("Apri BeepBar al login", "Open BeepBar at login"), explanation: tr("BeepBar si apre da sola ogni volta che accendi il Mac o accedi. Così la sincronizzazione automatica continua anche dopo un riavvio, senza doverti ricordare di aprirla.", "BeepBar opens by itself whenever you turn on or log in to your Mac. That way automatic sync keeps going after a restart, without you having to remember to open it."))
            }
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

    /// Automatic sync, how often it runs, and "Risparmio dati", which only affects automatic sync
    /// and is therefore greyed out with it.
    private var automaticSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { authentication.automaticSyncEnabled },
                set: { authentication.setAutomaticSync(enabled: $0) }
            )) {
                SettingLabel(tr("Sincronizzazione automatica", "Automatic sync"), explanation: tr("BeepBar controlla da sola i corsi che hai scelto e scarica i nuovi materiali, anche con la finestra chiusa. Non sovrascrive mai i file che hai modificato tu.", "BeepBar checks the courses you picked on its own and downloads new materials, even with the window closed. It never overwrites files you've changed."))
            }
            Picker(selection: Binding(
                get: { authentication.automaticSyncInterval },
                set: { authentication.setAutomaticSyncInterval($0) }
            )) {
                ForEach(AutomaticSyncOption.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            } label: {
                SettingLabel(tr("Frequenza", "Frequency"), explanation: tr("Ogni quanto BeepBar controlla se ci sono nuovi materiali. Il momento preciso lo sceglie macOS, per risparmiare batteria.", "How often BeepBar checks for new materials. macOS picks the exact moment, to save battery."))
            }
            .disabled(!authentication.automaticSyncEnabled)
            Toggle(isOn: Binding(
                get: { authentication.dataSaverEnabled },
                set: { authentication.setDataSaver(enabled: $0) }
            )) {
                SettingLabel(tr("Risparmio dati", "Data Saver"), explanation: tr("Quando il Mac usa l'hotspot del telefono, la sincronizzazione automatica si mette in pausa per non consumare i tuoi dati, e riprende da sola quando torni sul Wi-Fi. Vale anche per le reti con la Modalità dati ridotti. «Sincronizza ora» scarica sempre.", "When your Mac is using your phone's hotspot, automatic sync pauses so it doesn't use up your data, and picks up again by itself once you're back on Wi-Fi. The same goes for networks with Low Data Mode on. “Sync now” always downloads."))
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
            Toggle(isOn: Binding(
                get: { authentication.notificationsEnabled },
                set: { enabled in Task { await authentication.setNotifications(enabled: enabled) } }
            )) {
                SettingLabel(tr("Notifiche", "Notifications"), explanation: tr("BeepBar ti avvisa quando arrivano nuovi materiali, quando devi scegliere quale versione di un file tenere, o se la sincronizzazione ha un problema.", "BeepBar lets you know when new materials arrive, when you need to choose which version of a file to keep, or if syncing runs into a problem."))
            }
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
            Toggle(isOn: $checksForUpdates) {
                SettingLabel(tr("Controlla automaticamente gli aggiornamenti", "Check for updates automatically"), explanation: tr("BeepBar controlla da sola se c'è una nuova versione e ti avvisa. Se lo spegni, puoi sempre controllare tu con «Cerca aggiornamenti…».", "BeepBar checks for a new version on its own and lets you know. If you turn this off, you can still check yourself with “Check for updates…”."))
            }
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

private struct SessionDeletionWarning: View {
    @ObservedObject var recordings: RecordingsController

    var body: some View {
        if recordings.studyDeletionFailed {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("La cronologia precedente non è più usata, ma alcuni file non sono stati eliminati dal Mac.", "Previous history is no longer used, but some files could not be deleted from your Mac."))
                    .foregroundStyle(.orange)
                Button(tr("Riprova a eliminare la cronologia", "Retry deleting history")) { recordings.retryStudyDeletion() }
            }
        }
        if recordings.sessionDeletionFailed {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("Cancellazione della sessione non riuscita: cookie ed email potrebbero essere ancora sul disco. Disattiva Registrazioni e riprova.", "Session deletion failed: cookies and email may still be on disk. Turn Recordings off and retry."))
                    .foregroundStyle(.orange)
                Button(tr("Riprova la cancellazione", "Retry deletion")) { recordings.retrySessionDeletion() }
                    .disabled(recordings.isEnabled)
            }
        }
    }
}

private struct RecordingsSettingsSection: View {
    @ObservedObject var recordings: RecordingsController
    @State private var showForgetConfirmation = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { recordings.isEnabled }, set: { recordings.setEnabled($0) })) {
                SettingLabel(tr("Registrazioni delle lezioni", "Lecture recordings"), explanation: tr("Aggiunge la pagina Registrazioni, con le lezioni registrate dei corsi che sincronizzi, prese dall'archivio del Politecnico. Serve un accesso al Politecnico, che dura circa dieci giorni.", "Adds the Recordings page, with the recorded lectures of the courses you sync, taken from Polimi's archive. It needs a Polimi sign-in, which lasts about ten days."))
            }
            .disabled(!recordings.isEnabled && !recordings.canTurnOn)
            switch recordings.access {
            case .signingIn:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("Accesso al Politecnico in corso…", "Signing in to Polimi…")).foregroundStyle(.secondary)
                }
            case .needsSignIn(let problem):
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr("Serve l'accesso al Politecnico", "Polimi sign-in needed"))
                        if let problem {
                            Text(problem.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(tr("Accedi con Polimi", "Sign in with Polimi")) { recordings.signIn() }
                }
            case .ready, .off:
                EmptyView()
            }
            if recordings.isEnabled {
                RecordingsEmailField(recordings: recordings)
            }
            Button(tr("Dimentica i dati di studio di questo account…", "Forget this account’s study data…"), role: .destructive) { showForgetConfirmation = true }
                .disabled(!recordings.canForgetStudyData)
                .confirmationDialog(tr("Dimenticare i dati di studio?", "Forget study data?"), isPresented: $showForgetConfirmation, titleVisibility: .visible) {
                    Button(tr("Dimentica i dati di studio", "Forget study data"), role: .destructive) { recordings.forgetStudyData() }
                    Button(tr("Annulla", "Cancel"), role: .cancel) {}
                } message: {
                    Text(tr("Elimina watchlist, stato di visione e posizioni di ripresa di questo account e chiude la lezione in riproduzione. I materiali scaricati restano sul Mac.", "Deletes this account’s watchlist, viewing state and resume positions, and closes the playing lecture. Downloaded materials stay on your Mac."))
                }
        } header: {
            Text(tr("Registrazioni", "Recordings"))
        } footer: {
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: String {
        if !recordings.isEnabled && !recordings.canTurnOn {
            return tr("Collega prima il tuo account WeBeep.", "Connect your WeBeep account first.")
        }
        return tr("L'accesso al Politecnico e a Webex e l'email restano solo su questo Mac, leggibili solo dal tuo utente. Spegnendo l'interruttore o disconnettendo l'account vengono cancellati.", "The Polimi and Webex sign-ins and the email stay on this Mac only, readable only by your user. Turning the switch off or disconnecting the account deletes them.")
    }
}

/// The Polimi email Webex asks for when a recording is played inside BeepBar (#148). By product
/// decision (2026-10-11) the WeBeep profile's address, when the account allows reading it, is in
/// use without a confirmation step (`RecordingsController.learnEmail`, also run by the first
/// Play); this row shows the address in use, says where it came from, and lets the student change
/// or remove it, which wins over the profile (rules in `RecordingsController.emailFieldState` and
/// `confirmEmail`).
private struct RecordingsEmailField: View {
    @ObservedObject var recordings: RecordingsController
    @State private var draft = ""
    /// What `draft` was last filled with, so a late suggestion never overwrites what the student typed.
    @State private var source = ""

    private var state: RecordingsController.EmailFieldState {
        RecordingsController.emailFieldState(draft: draft, confirmed: recordings.confirmedEmail)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                HStack(spacing: 8) {
                    TextField("", text: $draft, prompt: Text("nome.cognome@mail.polimi.it"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 230)
                        .accessibilityLabel(tr("Email del Politecnico", "Polimi email"))
                        .disabled(!recordings.canConfirmEmail)
                        .onSubmit(confirm)
                    Button(state == .removable ? tr("Rimuovi", "Remove") : tr("Conferma", "Confirm"), action: confirm)
                        .disabled(!canConfirm)
                }
            } label: {
                SettingLabel(tr("Email del Politecnico", "Polimi email"), explanation: tr("BeepBar prende l'indirizzo dal tuo profilo WeBeep e lo usa solo per accedere a Webex in automatico quando guardi una registrazione dentro l'app: lo manda a Webex per l'accesso e a nessun altro. Puoi cambiarlo o rimuoverlo qui. Resta su questo Mac, nello stesso file dell'accesso al Politecnico, e viene cancellato con lui.", "BeepBar takes the address from your WeBeep profile and uses it only to sign in to Webex automatically when you watch a recording inside the app: it sends it to Webex for that sign-in and to no one else. You can change or remove it here. It stays on this Mac, in the same file as your Polimi sign-in, and is deleted with it."))
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(state == .invalid ? Color.red : Color.secondary)
            }
        }
        .task {
            await recordings.prepareEmailField()
            fill()
        }
        .onChange(of: recordings.confirmedEmail) { _, _ in fill() }
    }

    private var canConfirm: Bool {
        guard recordings.canConfirmEmail else { return false }
        switch state {
        case .ready, .removable: return true
        case .empty, .confirmed, .invalid: return false
        }
    }

    private var note: String? {
        // No WeBeep account known (expired sign-in at launch): an address typed now would belong
        // to no account, so the field takes none until the student signs in again.
        if !recordings.canConfirmEmail {
            return tr("Accedi di nuovo a WeBeep per inserire l'indirizzo.", "Sign in to WeBeep again to enter the address.")
        }
        switch state {
        case .invalid:
            return tr("Serve un indirizzo del Politecnico (…@mail.polimi.it o …@polimi.it).", "A Polimi address is needed (…@mail.polimi.it or …@polimi.it).")
        case .confirmed where recordings.emailFromProfile:
            return tr("In uso, preso dal tuo profilo WeBeep. Puoi cambiarlo o rimuoverlo.", "In use, taken from your WeBeep profile. You can change or remove it.")
        case .confirmed:
            return tr("Indirizzo in uso.", "Address in use.")
        case .empty:
            return tr("Serve per guardare le registrazioni dentro BeepBar: senza, quelle che richiedono l'accesso a Webex non si aprono.", "Needed to watch recordings inside BeepBar: without it, those that need a Webex sign-in won't open.")
        case .ready, .removable:
            return nil
        }
    }

    private func confirm() {
        guard canConfirm else { return }
        recordings.confirmEmail(draft)
        draft = ""
        source = ""
        fill()
    }

    private func fill() {
        let latest = recordings.confirmedEmail?.value ?? ""
        if draft == source { draft = latest }
        source = latest
    }
}

/// The complete notice is bundled so it remains available before login and without network access.
enum PrivacyNotice {
    static var bundle: Bundle {
#if SWIFT_PACKAGE
        .module
#else
        .main
#endif
    }

    static func text(language: AppLanguage) throws -> String {
        guard let url = bundle.url(forResource: "privacy-notice", withExtension: "md") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let document = try String(contentsOf: url, encoding: .utf8)
        guard let italian = document.components(separatedBy: "## Italiano\n").dropFirst().first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let sections = italian.components(separatedBy: "## English\n")
        guard sections.count == 2 else { throw CocoaError(.fileReadCorruptFile) }
        let englishAndReferences = sections[1].components(separatedBy: "Provider documentation / documentazione del fornitore:")
        guard englishAndReferences.count == 2 else { throw CocoaError(.fileReadCorruptFile) }
        let localized = language == .italian ? sections[0] : englishAndReferences[0]
        return localized + "\nProvider documentation / documentazione del fornitore:" + englishAndReferences[1]
    }
}

struct PrivacyNoticeView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tr("Informativa privacy", "Privacy notice")).font(.title2)
            ScrollView {
                Text((try? PrivacyNotice.text(language: .current)) ?? tr(
                    "Informativa non disponibile. Contatta tommaso.vaccari@mail.polimi.it.",
                    "Privacy notice unavailable. Contact tommaso.vaccari@mail.polimi.it."))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(tr("Chiudi", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 560, height: 460)
    }
}
