import SwiftUI

/// Display-only badge showing the active profile in the top-trailing
/// corner of the tab shell. Non-focusable by construction
/// (`allowsHitTesting(false)`, no `.focusable`) so it can never steal
/// focus from the nav bar, an up-press from the leftmost Continue
/// Watching tile still lands on the Home tab (issue #25).
///
/// Only renders when the active server has more than one remembered
/// profile. Single-user setups never see it, knowing "who am I" is
/// trivial there and the badge would be pure clutter. Switching
/// profiles stays in Settings -> Profil; this is purely a "who's
/// signed in" indicator.
struct ActiveUserBadge: View {
    @Environment(\.appState) private var appState
    @Environment(\.dependencies) private var dependencies

    /// Remembered-profile count for the active server. Recomputed only
    /// on identity changes (below), not per frame, so the keychain read
    /// stays cheap.
    @State private var rememberedCount = 0

    private let diameter: CGFloat = 36

    var body: some View {
        Group {
            if let user = appState.activeUser, rememberedCount > 1 {
                content(for: user)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: rememberedCount)
        .animation(.easeInOut(duration: 0.2), value: appState.activeUser?.id)
        // Recompute when the profile or server changes (switch in
        // Settings, or a full server switch). serverDidSwitch is folded
        // into the identity so a same-user server change still re-reads.
        .task(id: badgeIdentity) {
            recomputeCount()
        }
    }

    private var badgeIdentity: String {
        let serverID = appState.activeServer?.id ?? ""
        let userID = appState.activeUser?.id ?? ""
        return "\(serverID)|\(userID)|\(appState.serverDidSwitch)"
    }

    private func recomputeCount() {
        guard let serverID = appState.activeServer?.id else {
            rememberedCount = 0
            return
        }
        rememberedCount = dependencies.listRememberedUsers(serverID: serverID).count
    }

    // MARK: - Content

    private func content(for user: JellyfinUser) -> some View {
        HStack(spacing: 8) {
            Text(user.name)
                .font(.callout)
                .fontWeight(.medium)
                .foregroundStyle(.white)
                .lineLimit(1)
            avatar(for: user)
        }
        // Tight insets so the avatar nearly defines the pill height,
        // reading as a compact account chip rather than a heavy bar.
        .padding(.leading, 18)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        // Match the frosted "text bubble" panels on the detail views
        // (.ultraThinMaterial): more presence than a plain white
        // translucency so it doesn't wash out, but lighter than the
        // .regularMaterial that read too dark.
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(
            Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        // Cap the pill width and right-anchor it. Short names stay tight
        // (the pill hugs its content, no hollow); a long display name
        // truncates instead of growing left into the tab-bar pills. The
        // cap is generous, normal names never hit it.
        .frame(maxWidth: 360, alignment: .trailing)
        // The pill rides at the title-safe top; the small negative
        // offset lifts its center level with the centered tab-bar pills,
        // which sit a touch above the title-safe inset. Trailing inset
        // sits it close to the safe edge, well clear of the tab bar.
        .padding(.trailing, 6)
        .offset(y: -4)
        .allowsHitTesting(false)
    }

    private func avatar(for user: JellyfinUser) -> some View {
        ZStack {
            if let url = dependencies.jellyfinImageService.userProfileImageURL(
                userID: user.id,
                tag: user.primaryImageTag
            ) {
                AsyncCachedImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    initialsCircle(for: user)
                }
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
            } else {
                initialsCircle(for: user)
                    .frame(width: diameter, height: diameter)
            }
        }
        .overlay(
            Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
    }

    private func initialsCircle(for user: JellyfinUser) -> some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Text(initials(for: user.name))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}
