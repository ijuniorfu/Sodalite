import Testing
import SwiftUI
@testable import Sodalite

/// Sodalite#140. The rail has three states and exactly one rule between them: focus wins. Pinned
/// here because the fills come from two different families in `Color.Theme` and mixing them is the
/// documented mistake.
struct SidebarItemStateTests {

    @Test("focus beats selection, including on the selected row")
    func focusWins() {
        #expect(SidebarItemState.resolve(isFocused: true, isSelected: true) == .focused)
        #expect(SidebarItemState.resolve(isFocused: true, isSelected: false) == .focused)
        #expect(SidebarItemState.resolve(isFocused: false, isSelected: true) == .selected)
        #expect(SidebarItemState.resolve(isFocused: false, isSelected: false) == .rest)
    }

    @Test("the focused row inverts, so it carries no accent")
    func focusedRowInverts() {
        #expect(SidebarItemState.focused.fill == .white)
        #expect(SidebarItemState.focused.labelColor == .black)
        #expect(SidebarItemState.focused.usesAccentIcon == false)
    }

    @Test("rest and selected carry the accent and differ only in their fill")
    func restAndSelectedCarryTheAccent() {
        #expect(SidebarItemState.rest.usesAccentIcon)
        #expect(SidebarItemState.selected.usesAccentIcon)
        #expect(SidebarItemState.rest.labelColor == .white)
        #expect(SidebarItemState.selected.labelColor == .white)
        // Focus goes WHITE here, so the resting family is restFill, never restFillStrong.
        #expect(SidebarItemState.selected.fill == Color.Theme.restFill)
        #expect(SidebarItemState.rest.fill == Color.clear)
    }
}
