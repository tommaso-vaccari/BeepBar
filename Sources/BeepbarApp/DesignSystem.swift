import AppKit
import BeepbarCore
import SwiftUI

// Shared building blocks for the configuration window. Animations only run on discrete state
// changes; the only timer is the once-a-minute refresh of "Sincronizzato N minuti fa". The whole
// hierarchy is torn down when the window closes (see ConfigurationWindowController), so none of
// this costs anything while Beepbar sits in the menu bar.

enum BeepbarStyle {
    static let cardRadius: CGFloat = 12
    static let pagePadding: CGFloat = 24
    static let snappy = Animation.snappy(duration: 0.28)
    /// Dates follow the app language chosen in Settings, not the system one, to match the copy.
    static var locale: Locale { AppLanguage.current.locale }
}

extension Date {
    var relativeText: String {
        formatted(.relative(presentation: .named).locale(BeepbarStyle.locale))
    }

    var shortText: String {
        formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(BeepbarStyle.locale))
    }
}

/// Grouped surface in the style of System Settings: control-background fill with a hairline
/// border, so it reads correctly in both light and dark mode without materials.
struct CardBackground: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: BeepbarStyle.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: BeepbarStyle.cardRadius, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardBackground(padding: padding)) }
}

/// Rounded, tinted square holding an SF Symbol — the icon tiles used for rows and headers.
struct SymbolTile: View {
    let systemImage: String
    var tint: Color = .accentColor
    var size: CGFloat = 28
    var filled = true

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(filled ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.14)))
            }
            .accessibilityHidden(true)
    }
}

/// Big number + caption, used for sync summaries.
struct MetricTile: View {
    let value: Int
    let label: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(label)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            Text(value, format: .number)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(value == 0 ? .secondary : .primary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Small rounded count pill ("3 nuovi").
struct CountPill: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Inline, non-modal error or warning strip.
struct NoticeBanner: View {
    let text: String
    var systemImage = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
    }
}

/// Section title with optional trailing accessory, placed above a card.
struct SectionHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            accessory
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// The one place the automatic-check cadence is spelled out, so Home and Settings can never
/// disagree on labels again.
enum AutomaticSyncOption: Int, CaseIterable, Identifiable {
    case halfHour = 1_800, hourly = 3_600, twoHours = 7_200, fourHours = 14_400, thriceDaily = 28_800

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .halfHour: tr("Ogni 30 minuti", "Every 30 minutes")
        case .hourly: tr("Ogni ora", "Every hour")
        case .twoHours: tr("Ogni 2 ore", "Every 2 hours")
        case .fourHours: tr("Ogni 4 ore", "Every 4 hours")
        case .thriceDaily: tr("3 volte al giorno", "3 times a day")
        }
    }
}

extension AppSyncState {
    var tint: Color {
        switch self {
        case .synced: .green
        case .conflicts, .partial, .loginRequired, .needsFolder, .failed: .orange
        case .recoveryBlocked: .red
        case .starting, .readyUnchecked, .checking, .syncing, .cancelling: .accentColor
        }
    }
}

enum Finder {
    /// Selects `url` in Finder, falling back to the closest existing ancestor so the action
    /// never silently does nothing when a folder hasn't been created yet.
    @MainActor static func reveal(_ url: URL) {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
            candidate.deleteLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([candidate])
    }
}

/// The app icon (App/Assets.xcassets/BeepbarLogo, vector) with an optional status badge in the
/// corner, so the brand stays constant and only the badge speaks about state.
struct BeepbarLogo: View {
    var size: CGFloat = 40
    var badge: String?
    var badgeTint: Color = .green
    /// Spoken instead of the image; the badge itself is decorative.
    var accessibilityLabel = "BeepBar"

    private static let hasAsset = NSImage(named: "BeepbarLogo") != nil

    var body: some View {
        Group {
            if Self.hasAsset {
                Image("BeepbarLogo")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // `swift build` binaries don't compile the asset catalog.
                SymbolTile(systemImage: "arrow.triangle.2.circlepath", tint: .blue, size: size * 0.9)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if let badge {
                Image(systemName: badge)
                    .font(.system(size: size * 0.38, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, badgeTint)
                    .background(Circle().fill(Color(nsColor: .controlBackgroundColor)).padding(-2))
                    .offset(x: size * 0.1, y: size * 0.1)
                    .transition(.scale.combined(with: .opacity))
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isImage)
    }
}

extension AppSyncState {
    /// Corner badge for the logo; nil when there's nothing worth flagging.
    var badgeSymbol: String? {
        switch self {
        case .synced: "checkmark.circle.fill"
        case .checking, .syncing, .cancelling: "arrow.triangle.2.circlepath.circle.fill"
        case .conflicts, .partial, .loginRequired, .needsFolder, .failed, .recoveryBlocked: "exclamationmark.circle.fill"
        case .starting, .readyUnchecked: nil
        }
    }
}
