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

    /// One `shellLayout` change, resolved into whether to land on Home and which layout to keep
    /// comparing later changes against.
    ///
    /// A switch and the shell it produces do not have to move in the same update. The optional Live
    /// TV and Music tabs are published after two awaited probes, so a switch to a profile on another
    /// server (or one where those libraries differ) settles the profile first and changes the tab set
    /// one or more updates later, with the same profile on both sides of that update. Judged against
    /// the immediately previous value alone, exactly the switch this rule exists for reads as no
    /// change at all. So a switch that has not moved the shell yet keeps the layout it left, and the
    /// next change is judged against that instead.
    ///
    /// The caller drops the latch once the viewer navigates: after that, a tab appearing is the
    /// viewer's own doing and not the switch's.
    static func resolveSwitch(previous: ProfileShellLayout,
                              current: ProfileShellLayout,
                              armedOrigin: ProfileShellLayout?) -> (landsOnHome: Bool, origin: ProfileShellLayout?) {
        if previous.profile != current.profile {
            guard previous.profile != nil, current.profile != nil else { return (false, nil) }
            return switchLandsOnHome(from: previous, to: current) ? (true, nil) : (false, previous)
        }
        guard let origin = armedOrigin else { return (false, nil) }
        return switchLandsOnHome(from: origin, to: current) ? (true, nil) : (false, origin)
    }
}
