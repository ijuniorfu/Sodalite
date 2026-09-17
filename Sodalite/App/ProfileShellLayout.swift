import Foundation

/// What the shell looks like for the profile on screen. Profiles carry their own tabs, navigation
/// style and accent, and a switch that changes any of them gets a fresh shell and lands on Home, a
/// defined destination instead of a Settings stack torn down mid-navigation (Sodalite#62, #141). A
/// switch between two profiles with the same shell rebuilds nothing and stays where it is.
///
/// The tint is part of it because the tvOS tab bar does not repaint a live instance: its colour comes
/// from the appearance proxy at creation, and the proxy is only updated in the same pass that already
/// built the bar, so the previous profile's colour stayed until the next tab change (measured on
/// Schlafzimmer, 2026-09-17). Only a bar created after the update carries the new colour.
struct ProfileShellLayout: Equatable {
    let profile: ProfileKey?
    let tabs: [AppTab]
    let style: AppearancePreferences.NavigationStyle
    let tint: UInt32

    static func switchLandsOnHome(from old: ProfileShellLayout, to new: ProfileShellLayout) -> Bool {
        guard let before = old.profile, let after = new.profile, before != after else { return false }
        return old.tabs != new.tabs || old.style != new.style || old.tint != new.tint
    }
}
