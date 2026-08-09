import Foundation

/// Sodalite#62: switching the Catalog tab off also switches off the other Seerr browse surfaces
/// (the Catalog section in Search, the person filmography). They show the same unavailable,
/// requestable titles, so leaving them on would put the hidden catalog one level deeper instead
/// of away. Requesting from a Jellyfin detail page is unaffected: that is about owned content.
enum SeerrSurfacePolicy {

    @MainActor
    static func browsingEnabled(appState: AppState, appearance: AppearancePreferences) -> Bool {
        appState.isSeerrConnected && !appearance.isTabHidden(.catalog)
    }
}
