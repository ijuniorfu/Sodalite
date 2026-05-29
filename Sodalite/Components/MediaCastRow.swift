import SwiftUI

/// Source-neutral cast member, so both the Jellyfin and Seerr detail
/// views can feed the same row. `personID` is the TMDB person id used
/// for navigation to a filmography page (SP2); nil disables the tap.
struct CastMember: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let role: String?
    let imageURL: URL?
    let personID: Int?
}

/// Horizontal strip of cast portraits. `onSelect` is nil in SP1 (the
/// cards are non-interactive); SP2 wires it to push a person page.
struct MediaCastRow: View {
    var title: LocalizedStringKey = "detail.cast"
    let members: [CastMember]
    var onSelect: ((CastMember) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
                .padding(.horizontal, 50)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 20) {
                    ForEach(members) { member in
                        MediaCastCard(member: member, onSelect: onSelect.map { cb in { cb(member) } })
                    }
                }
                .padding(.horizontal, 50)
                .padding(.vertical, 12)
            }
        }
    }
}

private struct MediaCastCard: View {
    let member: CastMember
    var onSelect: (() -> Void)? = nil
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            AsyncCachedImage(url: member.imageURL) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Text(initials)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 100, height: 100)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(.tint, lineWidth: 3)
                    .padding(-3)
                    .opacity(isFocused ? 1 : 0)
            )

            VStack(spacing: 2) {
                Text(member.name)
                    .font(.caption)
                    .lineLimit(1)
                if let role = member.role, !role.isEmpty {
                    Text(role)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 100)
        }
        .scaleEffect(isFocused ? 1.1 : 1.0)
        .shadow(color: .black.opacity(isFocused ? 0.3 : 0), radius: 10, y: 5)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .focusable()
        .focused($isFocused)
        .stableTap(isFocused: isFocused) { onSelect?() }
    }

    private var initials: String {
        let parts = member.name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(member.name.prefix(2)).uppercased()
    }
}
