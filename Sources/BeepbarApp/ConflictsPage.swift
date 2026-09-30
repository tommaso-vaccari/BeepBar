import SwiftUI
import BeepbarCore

/// The single conflict resolver: both the shell tab and the menu bar's "Apri conflitti"
/// action land here.
struct ConflictsPage: View {
    @ObservedObject var authentication: WeBeepAuthenticationController

    private var pendingCount: Int { authentication.conflicts.count + authentication.remoteChanges.count }
    private var isBusy: Bool { authentication.resolvingConflictID != nil || authentication.resolvingRemoteChangeID != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(
                    title: tr("Conflitti", "Conflicts"),
                    subtitle: pendingCount == 0 ? nil : tr("\(pendingCount) da risolvere", "\(pendingCount) to resolve")
                ) {
                    Button { authentication.refreshConflicts() } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .help(tr("Aggiorna l’elenco dei conflitti", "Refresh the conflict list"))
                    .accessibilityLabel(tr("Aggiorna conflitti", "Refresh conflicts"))
                }
                Label(tr("La versione remota è conservata separatamente: nessun file locale viene mai sovrascritto senza una tua scelta.", "The remote version is kept separately: no local file is ever overwritten without your choice."), systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if pendingCount == 0 {
                    ContentUnavailableView {
                        Label(tr("Nessun conflitto aperto", "No open conflicts"), systemImage: "checkmark.seal")
                    } description: {
                        Text(tr("Se lo stesso file cambia sia sul Mac sia su \(authentication.selectedSite.platformName), potrai scegliere qui quale versione tenere.", "If the same file changes both on your Mac and on \(authentication.selectedSite.platformName), you can choose here which version to keep."))
                    }
                    .frame(minHeight: 260)
                    .frame(maxWidth: .infinity)
                    .card()
                    .transition(.opacity)
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(authentication.conflicts) { conflict in
                            ConflictCard(
                                conflict: conflict,
                                localURL: authentication.rootURL?.appending(path: conflict.relativePath.value),
                                isResolving: authentication.resolvingConflictID == conflict.id,
                                isLocked: isBusy,
                                resolve: { authentication.resolve(conflict, with: $0) }
                            )
                            .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.96))))
                        }
                    }
                    if !authentication.remoteChanges.isEmpty {
                        Text(tr("Spostati o rimossi su \(authentication.selectedSite.platformName)", "Moved or removed on \(authentication.selectedSite.platformName)"))
                            .font(.headline)
                            .padding(.top, authentication.conflicts.isEmpty ? 0 : 8)
                        Text(tr("Beepbar non sposta né cancella un file che hai modificato, e non cancella mai niente da solo: scegli tu.", "Beepbar never moves a file you edited or deletes anything by itself: you choose."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        LazyVStack(spacing: 10) {
                            ForEach(authentication.remoteChanges) { change in
                                RemoteChangeCard(
                                    change: change,
                                    platformName: authentication.selectedSite.platformName,
                                    localURL: authentication.rootURL?.appending(path: change.relativePath.value),
                                    isResolving: authentication.resolvingRemoteChangeID == change.id,
                                    isLocked: isBusy,
                                    resolve: { authentication.resolve(change, with: $0) }
                                )
                                .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.96))))
                            }
                        }
                    }
                }
            }
            .padding(BeepbarStyle.pagePadding)
            .animation(BeepbarStyle.snappy, value: authentication.conflicts.map(\.id))
            .animation(BeepbarStyle.snappy, value: authentication.remoteChanges.map(\.id))
        }
    }
}

private struct ConflictCard: View {
    let conflict: ConflictRecord
    let localURL: URL?
    let isResolving: Bool
    let isLocked: Bool
    let resolve: (ConflictResolution) -> Void

    private var fileName: String { (conflict.relativePath.value as NSString).lastPathComponent }
    private var directory: String { (conflict.relativePath.value as NSString).deletingLastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                SymbolTile(systemImage: "doc.on.doc.fill", tint: .orange, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(fileName)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    if !directory.isEmpty {
                        Label(directory, systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(tr("Rilevato \(conflict.detectedAt.relativeText)", "Detected \(conflict.detectedAt.relativeText)"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                if let localURL {
                    Button { Finder.reveal(localURL) } label: {
                        Image(systemName: "magnifyingglass.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(tr("Mostra la copia locale nel Finder", "Show the local copy in Finder"))
                    .accessibilityLabel(tr("Mostra \(fileName) nel Finder", "Show \(fileName) in Finder"))
                }
            }
            HStack(spacing: 10) {
                choice(title: tr("Mantieni la mia", "Keep mine"), subtitle: tr("La copia sul Mac resta com’è", "The copy on your Mac stays as it is"), systemImage: "laptopcomputer", prominent: false) {
                    resolve(.keepLocal)
                }
                choice(title: tr("Usa la versione remota", "Use the remote version"), subtitle: tr("Sostituisce la copia locale", "Replaces the local copy"), systemImage: "icloud.and.arrow.down", prominent: true) {
                    resolve(.useRemote)
                }
            }
            .disabled(isLocked)
            .overlay {
                if isResolving { ProgressView().controlSize(.small) }
            }
        }
        .card()
    }

    private func choice(title: String, subtitle: String, systemImage: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(subtitle).font(.caption).opacity(0.8)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(.quaternary.opacity(0.7)))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isLocked && !isResolving ? 0.5 : 1)
    }
}

/// A file Moodle moved, removed or uploaded again, with the choices the sync behavior document
/// gives for it (section 4).
private struct RemoteChangeCard: View {
    let change: RemoteChange
    let platformName: String
    let localURL: URL?
    let isResolving: Bool
    let isLocked: Bool
    let resolve: (RemoteChangeAction) -> Void

    private var fileName: String { change.relativePath.components.last ?? change.relativePath.value }
    private var directory: String { change.relativePath.components.dropLast().joined(separator: "/") }
    private var targetFolder: String { change.targetPath.map { $0.components.dropLast().joined(separator: "/") } ?? "" }

    private var explanation: String {
        switch change.kind {
        case .moved:
            tr("Su \(platformName) ora è in “\(targetFolder)”. L’hai modificato, quindi è rimasto qui.", "On \(platformName) it is now in “\(targetFolder)”. You edited it, so it stayed here.")
        case .removed:
            change.isLocallyModified
                ? tr("Non è più su \(platformName). L’hai modificato.", "It is no longer on \(platformName). You edited it.")
                : tr("Non è più su \(platformName).", "It is no longer on \(platformName).")
        case .reuploaded:
            tr("Su \(platformName) è stato ricaricato in “\(targetFolder)”. La tua copia è modificata. Prima di spostarla nel Cestino o sostituire quella nuova, Beepbar verifica che il download sia disponibile.", "On \(platformName) it was uploaded again to “\(targetFolder)”. Your copy is edited. Before moving it to the Trash or replacing the new copy, Beepbar checks that the download is available.")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                SymbolTile(systemImage: change.kind == .removed ? "trash.circle.fill" : "arrow.right.circle.fill", tint: .purple, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(fileName)
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                    if !directory.isEmpty {
                        Label(directory, systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let localURL {
                    Button { Finder.reveal(localURL) } label: {
                        Image(systemName: "magnifyingglass.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(tr("Mostra il file nel Finder", "Show the file in Finder"))
                    .accessibilityLabel(tr("Mostra \(fileName) nel Finder", "Show \(fileName) in Finder"))
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { choices }
                VStack(spacing: 8) { choices }
            }
            .disabled(isLocked)
            .overlay {
                if isResolving { ProgressView().controlSize(.small) }
            }
        }
        .card()
    }

    @ViewBuilder private var choices: some View {
        ForEach(RemoteChangeAction.available(for: change.kind), id: \.self) { action in
            let copy = Self.copy(for: action, kind: change.kind)
            Button { resolve(action) } label: {
                HStack(spacing: 10) {
                    Image(systemName: copy.symbol)
                        .font(.title3)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(copy.title).font(.callout.weight(.semibold))
                        Text(copy.subtitle).font(.caption).opacity(0.8)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.quaternary.opacity(0.7))
                }
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .opacity(isLocked && !isResolving ? 0.5 : 1)
        }
    }

    private static func copy(for action: RemoteChangeAction, kind: RemoteChange.Kind) -> (title: String, subtitle: String, symbol: String) {
        switch action {
        case .moveMine:
            (tr("Sposta la mia versione nella nuova cartella", "Move my version to the new folder"), tr("Con le tue modifiche; se il nome è preso, con un numero", "With your edits; numbered if the name is taken"), "folder.badge.plus")
        case .leaveHere:
            (tr("Lascia qui", "Leave it here"), tr("Gli aggiornamenti arriveranno qui", "Updates will arrive here"), "pin")
        case .keep:
            (tr("Tieni", "Keep"), tr("Resta sul Mac come file tuo", "Stays on your Mac as your own file"), "tray.and.arrow.down")
        case .trash:
            kind == .reuploaded
                ? (tr("Sposta la mia nel Cestino", "Move mine to the Trash"), tr("Resta la copia nuova", "The new copy stays"), "trash")
                : (tr("Sposta nel Cestino", "Move to the Trash"), tr("Si può recuperare dal Cestino", "You can recover it from the Trash"), "trash")
        case .replaceNewCopy:
            (tr("Sostituisci la copia nuova con la mia versione", "Replace the new copy with my version"), tr("La copia nuova va nel Cestino", "The new copy goes to the Trash"), "arrow.triangle.swap")
        case .keepBoth:
            (tr("Tieni entrambe", "Keep both"), tr("La tua resta com’è, fuori dalla sincronizzazione", "Yours stays as it is, no longer synced"), "square.on.square")
        }
    }
}
