import Foundation

/// Pure ordering + initial-focus policy for the launch profile picker (issue #41):
/// the active-session profile sorts first, focus prefers the configured default,
/// then the active profile, then the first card.
enum ProfilePickerOrdering {
    static func orderedForPicker(_ users: [RememberedUser], activeID: String?) -> [RememberedUser] {
        guard let activeID,
              let index = users.firstIndex(where: { $0.id == activeID }),
              index != 0
        else { return users }
        var result = users
        let active = result.remove(at: index)
        result.insert(active, at: 0)
        return result
    }

    static func preferredFocusID(users: [RememberedUser], defaultID: String?, activeID: String?) -> String? {
        if let defaultID, users.contains(where: { $0.id == defaultID }) { return defaultID }
        if let activeID, users.contains(where: { $0.id == activeID }) { return activeID }
        return users.first?.id
    }
}
