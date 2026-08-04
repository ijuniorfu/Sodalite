import SwiftUI
import UIKit

// MARK: - SwiftUI content

/// One program block. Focus fills tinted with black text, the app's convention for a focused
/// surface (see PopoverActionButton); an airing program keeps a tinted outline while unfocused so
/// the live column reads at a glance.
struct GuideProgramCellContent: View {
    let title: String
    let timeRange: String?
    let isAiring: Bool
    let hasTimer: Bool
    let isFocused: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            if hasTimer {
                Circle().fill(.red).frame(width: 10, height: 10)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(isFocused ? Color.black : Color.white)
                if let timeRange {
                    Text(timeRange)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(isFocused ? Color.black.opacity(0.7) : Color.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isFocused ? AnyShapeStyle(tint) : AnyShapeStyle(Color.Theme.surfaceElevated))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isAiring ? tint : Color.white.opacity(0.12),
                              lineWidth: isAiring ? 2 : 1)
        )
        .padding(EdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2))
        // A three-minute program is a cell a few points wide. Clipping beats letting the label push
        // the block's own geometry around.
        .clipped()
    }
}

/// Channel column cell. Card-shaped, so it takes the semantic focus ring rather than the program
/// block's tint fill.
struct GuideChannelCellContent: View {
    let name: String
    let number: String?
    let logoURL: URL?
    let isFavorite: Bool
    let isFocused: Bool
    let metrics: GuideMetrics

    var body: some View {
        HStack(spacing: 12) {
            AsyncCachedImage(url: logoURL) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Image(systemName: "tv")
                    .font(.system(size: metrics.channelLogoSize * 0.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: metrics.channelLogoSize, height: metrics.channelLogoSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline).lineLimit(1)
                if let number {
                    Text(number).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isFavorite {
                Image(systemName: "star.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.yellow)
                    .frame(width: metrics.favoriteIconSize, height: metrics.favoriteIconSize)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Theme.surface)
        .overlay(MediaFocusRing(shape: Rectangle(), isFocused: isFocused))
    }
}

/// One half-hour chip. Exactly one slot wide, so its edges meet the grid's lines.
struct GuideRulerCellContent: View {
    let label: String
    /// Set on the first chip of a day so a 48h axis does not show two unlabelled "00:00".
    let dayLabel: String?
    let isFocused: Bool
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let dayLabel {
                Text(dayLabel)
                    .font(.caption2)
                    .foregroundStyle(isFocused ? Color.black.opacity(0.7) : Color.secondary)
            }
            Text(label)
                .font(.caption)
                .fontWeight(isFocused ? .semibold : .regular)
                .foregroundStyle(isFocused ? Color.black : Color.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isFocused ? AnyShapeStyle(tint) : AnyShapeStyle(Color.clear))
        )
        .padding(.vertical, 4)
    }
}

// MARK: - UIKit hosts

/// `UIHostingConfiguration` creates a DETACHED SwiftUI hierarchy: nothing is inherited from the view
/// that hosts the controller. Without this injection AsyncCachedImage has no base URL and
/// MediaFocusRing draws the default accent instead of the user's.
private extension View {
    func guideCellEnvironment(_ dependencies: DependencyContainer,
                              _ theme: ResolvedAppearanceTheme) -> some View {
        environment(\.dependencies, dependencies)
            .environment(\.appearanceTheme, theme)
    }
}

final class GuideProgramCell: UICollectionViewCell {
    static let reuseID = "GuideProgramCell"

    func configure(title: String, timeRange: String?, isAiring: Bool, hasTimer: Bool,
                   tint: Color, dependencies: DependencyContainer,
                   theme: ResolvedAppearanceTheme) {
        // configurationUpdateHandler reruns on every state change, which is how the focus fill
        // tracks without a manual didUpdateFocus override.
        configurationUpdateHandler = { cell, state in
            cell.contentConfiguration = UIHostingConfiguration {
                GuideProgramCellContent(
                    title: title, timeRange: timeRange, isAiring: isAiring,
                    hasTimer: hasTimer, isFocused: state.isFocused, tint: tint)
                    .guideCellEnvironment(dependencies, theme)
            }
            .margins(.all, 0)
        }
        setNeedsUpdateConfiguration()
    }
}

final class GuideChannelCell: UICollectionViewCell {
    static let reuseID = "GuideChannelCell"

    func configure(name: String, number: String?, logoURL: URL?, isFavorite: Bool,
                   metrics: GuideMetrics, dependencies: DependencyContainer,
                   theme: ResolvedAppearanceTheme) {
        configurationUpdateHandler = { cell, state in
            cell.contentConfiguration = UIHostingConfiguration {
                GuideChannelCellContent(
                    name: name, number: number, logoURL: logoURL, isFavorite: isFavorite,
                    isFocused: state.isFocused, metrics: metrics)
                    .guideCellEnvironment(dependencies, theme)
            }
            .margins(.all, 0)
        }
        setNeedsUpdateConfiguration()
    }
}

final class GuideRulerCell: UICollectionViewCell {
    static let reuseID = "GuideRulerCell"

    func configure(label: String, dayLabel: String?, tint: Color,
                   dependencies: DependencyContainer, theme: ResolvedAppearanceTheme) {
        configurationUpdateHandler = { cell, state in
            cell.contentConfiguration = UIHostingConfiguration {
                GuideRulerCellContent(
                    label: label, dayLabel: dayLabel, isFocused: state.isFocused, tint: tint)
                    .guideCellEnvironment(dependencies, theme)
            }
            .margins(.all, 0)
        }
        setNeedsUpdateConfiguration()
    }
}

// MARK: - Decorations

final class GuideNowLineView: UICollectionReusableView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemRed
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Half-hour vertical tick, drawn behind the cells (layout zIndex -1).
final class GuideGridLineView: UICollectionReusableView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.white.withAlphaComponent(0.06)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
