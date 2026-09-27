import SwiftUI
import BeepbarCore

/// What the last synchronization brought in, course by course.
struct ActivityPage: View {
    @ObservedObject var authentication: WeBeepAuthenticationController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let summary = authentication.lastSyncSummary {
                    SectionHeader(title: tr("Ultima sincronizzazione", "Last sync"), subtitle: summary.completedAt.shortText)
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
                                    folderURL: authentication.rootURL?.appending(path: course.courseFolder, directoryHint: .isDirectory)
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
    @State private var isExpanded = false

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
                        Label {
                            Text(item.name).font(.callout).lineLimit(1)
                        } icon: {
                            Image(systemName: item.kind == .added ? "plus.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                                .foregroundStyle(item.kind == .added ? .green : .blue)
                        }
                    }
                    ForEach(course.movedItems) { item in
                        Label {
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
}

private extension MovedSyncItem {
    /// Where the file went, or why it stayed. Built at display time so it follows a language switch.
    func explanation(platform: String) -> String {
        let place = folder.isEmpty ? tr("nella cartella del corso", "in the course folder") : tr("in “\(folder)”", "to “\(folder)”")
        switch outcome {
        case .moved:
            return tr("Spostato \(place), come su \(platform)", "Moved \(place), as on \(platform)")
        case .keptEdited:
            return tr("Su \(platform) ora è \(place). L’hai modificato: scegli in Conflitti se spostarlo", "Now \(place) on \(platform). You edited it: choose in Conflicts whether to move it")
        }
    }
}
