import SwiftUI

/// Sodalite#140. One row of the sidebar has three looks. Focus wins over selection, because a
/// viewer moving through the rail needs to see where they are before they see where they were.
///
/// The fills come from the family whose focus goes WHITE (`restFill` / `restFillFaint`), not from
/// `restFillStrong`, which belongs to surfaces that lift into the TINT on focus. Mixing the two is
/// the mistake `Color.Theme` warns about.
enum SidebarItemState: Equatable {
    case rest
    case selected
    case focused

    static func resolve(isFocused: Bool, isSelected: Bool) -> SidebarItemState {
        if isFocused { return .focused }
        return isSelected ? .selected : .rest
    }

    var fill: Color {
        switch self {
        case .rest: .clear
        case .selected: Color.Theme.restFill
        case .focused: .white
        }
    }

    /// The focused row is a white pill, so its contents go black and the accent steps aside.
    var usesAccentIcon: Bool { self != .focused }

    var labelColor: Color {
        self == .focused ? .black : .white
    }

    /// Used when the accent cannot be resolved, which only happens in previews.
    var iconFallbackColor: Color {
        self == .focused ? .black : .white
    }
}
