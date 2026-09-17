import Testing
@testable import Sodalite

@Suite("Profile switch and the tab shell")
struct ProfileShellLayoutTests {
    private let alice = ProfileKey(serverID: "s", userID: "alice")
    private let bob = ProfileKey(serverID: "s", userID: "bob")

    private func layout(_ profile: ProfileKey?, _ tabs: [AppTab], _ style: AppearancePreferences.NavigationStyle = .topBar) -> ProfileShellLayout {
        ProfileShellLayout(profile: profile, tabs: tabs, style: style)
    }

    @Test func aSwitchToTheSameLayoutStaysPut() {
        #expect(!ProfileShellLayout.switchLandsOnHome(from: layout(alice, [.home, .settings]), to: layout(bob, [.home, .settings])))
    }

    @Test func aSwitchToOtherTabsLandsOnHome() {
        #expect(ProfileShellLayout.switchLandsOnHome(from: layout(alice, [.home, .catalog, .settings]), to: layout(bob, [.home, .settings])))
    }

    @Test func aSwitchToAnotherStyleLandsOnHome() {
        #expect(ProfileShellLayout.switchLandsOnHome(from: layout(alice, [.home], .topBar), to: layout(bob, [.home], .sidebar)))
    }

    /// Hiding a tab inside one profile is the existing onChange's job, and signing in or out is not a switch.
    @Test func onlyAChangeOfProfileCounts() {
        #expect(!ProfileShellLayout.switchLandsOnHome(from: layout(alice, [.home, .catalog]), to: layout(alice, [.home])))
        #expect(!ProfileShellLayout.switchLandsOnHome(from: layout(nil, [.home]), to: layout(alice, [.home, .catalog])))
    }
}
