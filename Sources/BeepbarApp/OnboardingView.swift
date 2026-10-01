import SwiftUI
import BeepbarCore

struct OnboardingView: View {
    @ObservedObject var authentication: WeBeepAuthenticationController
    @State private var step: Step = .welcome
    @State private var movingForward = true

    private enum Step: Int, CaseIterable { case welcome, folder, wrapUp }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            Group {
                switch step {
                case .welcome: welcomeStep
                case .folder: folderStep
                case .wrapUp: wrapUpStep
                }
            }
            .frame(maxWidth: 440)
            .id(step)
            .transition(.asymmetric(
                insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity)
            ))
            Spacer(minLength: 16)
            footer
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func hero(_ systemImage: String) -> some View {
        SymbolTile(systemImage: systemImage, size: 72)
            .shadow(color: .accentColor.opacity(0.35), radius: 14, y: 6)
            .padding(.bottom, 4)
    }

    private var welcomeStep: some View {
        VStack(spacing: 14) {
            // First, before any other text, so the rest of the wizard reads in the chosen language.
            LanguagePicker(authentication: authentication)
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.bottom, 6)
            BeepbarLogo(size: 88)
                .shadow(color: .blue.opacity(0.35), radius: 16, y: 8)
                .padding(.bottom, 4)
            Text(tr("Benvenuto in BeepBar", "Welcome to BeepBar")).font(.largeTitle.weight(.bold))
            Text(tr("Sincronizza in sicurezza i materiali universitari sul tuo Mac.", "Safely sync your university materials to your Mac."))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 14) {
                onboardingPoint(systemImage: "lock.shield.fill", tint: .green, text: tr("Non sovrascrive mai il tuo lavoro: se modifichi un file in locale, quella copia resta intoccata.", "It never overwrites your work: if you edit a file locally, that copy stays untouched."))
                onboardingPoint(systemImage: "clock.arrow.circlepath", tint: .blue, text: tr("Controlla i nuovi materiali in background, con la frequenza che scegli tu.", "It checks for new materials in the background, as often as you choose."))
                onboardingPoint(systemImage: "bolt.fill", tint: .orange, text: tr("Nativo e leggero: vive nella barra dei menu, senza appesantire il Mac.", "Native and lightweight: it lives in the menu bar without slowing down your Mac."))
            }
            .card(padding: 18)
            .padding(.top, 10)
        }
    }

    private var folderStep: some View {
        VStack(spacing: 14) {
            hero("folder.fill.badge.gearshape")
            Text(tr("Scegli la cartella dei materiali", "Choose the materials folder")).font(.title.weight(.bold))
            Text(tr("Qui dentro verrà creata una sottocartella per ogni corso che abiliterai.", "A subfolder will be created in here for each course you enable."))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let rootURL = authentication.rootURL {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                    Text((rootURL.path as NSString).abbreviatingWithTildeInPath)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .card(padding: 12)
                .padding(.top, 4)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            Button(authentication.rootURL == nil ? tr("Scegli cartella…", "Choose folder…") : tr("Cambia cartella…", "Change folder…")) {
                authentication.chooseRoot()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
            if case .failed = authentication.syncState, authentication.rootURL == nil {
                Text(authentication.syncState.detail)
                    .font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Text(tr("Nessun problema, potrai cambiarla in qualsiasi momento da Impostazioni.", "No worries, you can change it any time in Settings."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .animation(BeepbarStyle.snappy, value: authentication.rootURL)
    }

    private var wrapUpStep: some View {
        VStack(spacing: 14) {
            hero("checkmark.seal.fill")
            Text(tr("Ci siamo quasi", "Almost there")).font(.title.weight(.bold))
            accountBox
            VStack(alignment: .leading, spacing: 14) {
                onboardingPoint(systemImage: "slider.horizontal.3", tint: .blue, text: tr("Frequenza del controllo automatico e aggiornamenti dell'app: sempre modificabili da Impostazioni.", "How often to check automatically and app updates: you can change both any time in Settings."))
                onboardingPoint(systemImage: "exclamationmark.triangle.fill", tint: .orange, text: tr("Se un file cambia sia sul tuo Mac sia su \(authentication.selectedSite.platformName), lo trovi nella sezione Conflitti: decidi tu quale versione tenere.", "If a file changes both on your Mac and on \(authentication.selectedSite.platformName), you'll find it in the Conflicts section: you decide which version to keep."))
            }
            .padding(.top, 6)
        }
    }

    private var accountBox: some View {
        VStack(spacing: 12) {
            if !authentication.hasStoredCredential {
                MoodleSitePicker(authentication: authentication)
            }
            HStack(spacing: 12) {
                SymbolTile(
                    systemImage: authentication.hasStoredCredential ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.plus",
                    tint: authentication.hasStoredCredential ? .green : .accentColor,
                    size: 34
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Accedi a \(authentication.selectedSite.displayName)", "Sign in to \(authentication.selectedSite.displayName)")).font(.callout.weight(.medium))
                    Text(authentication.hasStoredCredential ? tr("Account collegato.", "Account connected.") : tr("Necessario per iniziare a sincronizzare i corsi.", "Needed to start syncing your courses."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if authentication.hasStoredCredential {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                } else {
                    Button(tr("Accedi…", "Sign in…")) { authentication.startLogin() }
                        .buttonStyle(.borderedProminent)
                        .disabled(authentication.isAuthenticating)
                }
            }
            if let feedback = authentication.authenticationFeedback {
                Text(feedback.text)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }

    private func onboardingPoint(systemImage: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SymbolTile(systemImage: systemImage, tint: tint, size: 28, filled: false)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { candidate in
                    Capsule()
                        .fill(candidate == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: candidate == step ? 18 : 6, height: 6)
                }
            }
            HStack {
                if step != .welcome {
                    Button(tr("Indietro", "Back")) { go(to: Step(rawValue: step.rawValue - 1) ?? .welcome) }
                        .controlSize(.large)
                }
                Spacer()
                if step == .wrapUp {
                    // Not the default action: Return must not skip past the sign-in above.
                    Button(tr("Inizia a usare BeepBar", "Start using BeepBar")) { authentication.completeOnboarding() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    Button(tr("Continua", "Continue")) { go(to: Step(rawValue: step.rawValue + 1) ?? .wrapUp) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(step == .folder && authentication.rootURL == nil)
                }
            }
        }
    }

    private func go(to target: Step) {
        movingForward = target.rawValue > step.rawValue
        withAnimation(BeepbarStyle.snappy) { step = target }
    }
}

/// Options always show their own name ("Italiano", "English") so they're findable from either
/// language; the label is bilingual for the same reason.
struct LanguagePicker: View {
    @ObservedObject var authentication: WeBeepAuthenticationController

    var body: some View {
        Picker("Lingua / Language", selection: Binding(
            get: { authentication.language },
            set: { authentication.setLanguage($0) }
        )) {
            ForEach(AppLanguage.allCases) { language in
                Text(language.nativeName).tag(language)
            }
        }
    }
}

struct MoodleSitePicker: View {
    @ObservedObject var authentication: WeBeepAuthenticationController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(tr("Università", "University"), selection: Binding(
                get: { authentication.selectedSite.university },
                set: { authentication.selectUniversity($0) }
            )) {
                ForEach(MoodleUniversity.allCases) { university in
                    Text(university.displayName).tag(university)
                }
            }
            if authentication.selectedSite.university == .unipd {
                Picker(tr("Area Moodle", "Moodle area"), selection: Binding(
                    get: { authentication.selectedSite },
                    set: { authentication.selectSite($0) }
                )) {
                    ForEach(MoodleSite.unipd) { site in
                        Text(site.displayName).tag(site)
                    }
                }
            }
        }
    }
}
