import SwiftUI

/// Admin-queue row. Differs from `SeerrRequestRow` in
/// `CatalogMyRequestsView` by (1) showing the requester's display
/// name and (2) carrying action buttons. The row itself is not
/// focusable as a single tap target. Focus lands on individual
/// action buttons, mirroring the deletion-sheet pattern.
struct SeerrRequestAdminRow: View {
    let request: SeerrRequest
    let title: String?
    let year: String?
    let posterURL: URL?
    let onApprove: () -> Void
    let onEdit: () -> Void
    let onDecline: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            poster

            VStack(alignment: .leading, spacing: 8) {
                Text(resolvedTitle)
                    .font(.body)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 10) {
                    Image(systemName: typeIcon)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(typeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let year {
                        Text("·").foregroundStyle(.tertiary)
                        Text(year).font(.caption).foregroundStyle(.secondary)
                    }
                    if request.type == .tv, let count = request.seasons?.count, count > 0 {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(count) \(seasonsLabel)").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Text("#\(request.id)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }

                if let requester = request.requestedBy {
                    Text(String(
                        format: String(
                            localized: "catalog.allRequests.requestedBy",
                            defaultValue: "Requested by %@"
                        ),
                        requester.resolvedDisplayName
                    ))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }

                SeerrEffectiveRequestBadge(request: request)

                actionRow
                    .padding(.top, 4)
            }

            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.05))
        )
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 12) {
            if request.status == .pendingApproval {
                AdminActionButton(
                    title: "catalog.allRequests.action.approve",
                    systemImage: "checkmark.circle.fill",
                    isProminent: true,
                    action: onApprove
                )
            }
            if request.status == .pendingApproval || request.status == .approved {
                AdminActionButton(
                    title: "catalog.allRequests.action.edit",
                    systemImage: "slider.horizontal.3",
                    action: onEdit
                )
            }
            if request.status == .pendingApproval {
                AdminActionButton(
                    title: "catalog.allRequests.action.decline",
                    systemImage: "xmark.circle",
                    action: onDecline
                )
            }
            AdminActionButton(
                title: "catalog.allRequests.action.delete",
                systemImage: "trash",
                isDestructive: true,
                action: onDelete
            )
        }
    }

    @ViewBuilder
    private var poster: some View {
        if let posterURL {
            AsyncCachedImage(url: posterURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                placeholderPoster
            }
            .frame(width: 80, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            placeholderPoster.frame(width: 80, height: 120)
        }
    }

    private var placeholderPoster: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08))
            Image(systemName: typeIcon).font(.title3).foregroundStyle(.tint)
        }
    }

    private var typeIcon: String {
        switch request.type {
        case .movie: "film"
        case .tv: "tv"
        case .person, .unknown: "person"
        }
    }

    private var typeLabel: String {
        switch request.type {
        case .movie: String(localized: "catalog.request.movie", defaultValue: "Movie")
        case .tv:    String(localized: "catalog.request.tv", defaultValue: "Series")
        case .person, .unknown: ""
        }
    }

    private var seasonsLabel: String {
        String(localized: "catalog.allRequests.seasonsLabel", defaultValue: "Seasons")
    }

    private var resolvedTitle: String {
        if let title, !title.isEmpty { return title }
        switch request.type {
        case .movie: return String(localized: "catalog.request.placeholder.movie", defaultValue: "Movie")
        case .tv:    return String(localized: "catalog.request.placeholder.tv", defaultValue: "Series")
        case .person, .unknown: return ""
        }
    }
}

/// Compact action button used in the admin row. Follows the
/// sodalite-ui-focus-and-tint rules: `.tint` ShapeStyle, focused
/// fill tinted not white, `.focusable` over material.
private struct AdminActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isProminent: Bool = false
    var isDestructive: Bool = false
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption)
            Text(title)
                .font(.callout)
                .fontWeight(.medium)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(backgroundStyle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.tint, lineWidth: 3)
                .opacity(focused ? 1 : 0)
        )
        .scaleEffect(focused ? 1.05 : 1.0)
        .focusable(true)
        .focused($focused)
        .stableTap(isFocused: focused) { action() }
        .animation(.easeInOut(duration: 0.15), value: focused)
    }

    private var backgroundStyle: AnyShapeStyle {
        if isDestructive {
            return AnyShapeStyle(Color.red.opacity(focused ? 0.85 : 0.6))
        }
        if isProminent {
            let opacity = focused ? 0.9 : 0.55
            return AnyShapeStyle(TintShapeStyle.tint.opacity(opacity))
        }
        if focused {
            return AnyShapeStyle(TintShapeStyle.tint.opacity(0.25))
        }
        return AnyShapeStyle(Color.white.opacity(0.12))
    }
}
