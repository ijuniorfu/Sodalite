import Testing
import Foundation
@testable import Sodalite

struct ProfilePickerOrderingTests {
    private func user(_ id: String) -> RememberedUser {
        RememberedUser(id: id, serverID: "s1", name: id, imageTag: nil, token: "t")
    }

    // MARK: orderedForPicker

    @Test func activeProfileMovesToFront() {
        let ordered = ProfilePickerOrdering.orderedForPicker(
            [user("kids"), user("parents"), user("guest")], activeID: "parents")
        #expect(ordered.map(\.id) == ["parents", "kids", "guest"])
    }

    @Test func activeAlreadyFirstKeepsOrder() {
        let ordered = ProfilePickerOrdering.orderedForPicker(
            [user("parents"), user("kids")], activeID: "parents")
        #expect(ordered.map(\.id) == ["parents", "kids"])
    }

    @Test func unknownActiveKeepsOrder() {
        let ordered = ProfilePickerOrdering.orderedForPicker(
            [user("kids"), user("parents")], activeID: "ghost")
        #expect(ordered.map(\.id) == ["kids", "parents"])
    }

    @Test func nilActiveKeepsOrder() {
        let ordered = ProfilePickerOrdering.orderedForPicker(
            [user("kids"), user("parents")], activeID: nil)
        #expect(ordered.map(\.id) == ["kids", "parents"])
    }

    @Test func emptyListStaysEmpty() {
        #expect(ProfilePickerOrdering.orderedForPicker([], activeID: "x").isEmpty)
    }

    // MARK: preferredFocusID

    @Test func focusPrefersDefaultWhenPresent() {
        let id = ProfilePickerOrdering.preferredFocusID(
            users: [user("parents"), user("kids")], defaultID: "kids", activeID: "parents")
        #expect(id == "kids")
    }

    @Test func focusFallsBackToActiveWhenDefaultMissing() {
        let id = ProfilePickerOrdering.preferredFocusID(
            users: [user("parents"), user("kids")], defaultID: "ghost", activeID: "parents")
        #expect(id == "parents")
    }

    @Test func focusFallsBackToActiveWhenNoDefault() {
        let id = ProfilePickerOrdering.preferredFocusID(
            users: [user("kids"), user("parents")], defaultID: nil, activeID: "parents")
        #expect(id == "parents")
    }

    @Test func focusFallsBackToFirstWhenActiveUnknown() {
        let id = ProfilePickerOrdering.preferredFocusID(
            users: [user("kids"), user("parents")], defaultID: nil, activeID: "ghost")
        #expect(id == "kids")
    }

    @Test func focusFallsBackToFirstWhenNothingSet() {
        let id = ProfilePickerOrdering.preferredFocusID(
            users: [user("kids"), user("parents")], defaultID: nil, activeID: nil)
        #expect(id == "kids")
    }

    @Test func focusNilOnEmptyList() {
        #expect(ProfilePickerOrdering.preferredFocusID(users: [], defaultID: nil, activeID: nil) == nil)
    }
}
