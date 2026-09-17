import Foundation

/// What the shell looks like for the profile on screen. Profiles carry their own tabs and navigation
/// style, and a switch that changes either rebuilds the shell under whatever screen was open, which
/// tears down a Settings stack mid-navigation (Sodalite#62, #141). Landing on Home gives that switch a
/// defined destination. A switch between two profiles with the same shell rebuilds nothing and stays.
struct ProfileShellLayout: Equatable {
    let profile: ProfileKey?
    let tabs: [AppTab]
    let style: AppearancePreferences.NavigationStyle

    static func switchLandsOnHome(from old: ProfileShellLayout, to new: ProfileShellLayout) -> Bool {
        guard let before = old.profile, let after = new.profile, before != after else { return false }
        return old.tabs != new.tabs || old.style != new.style
    }
}
