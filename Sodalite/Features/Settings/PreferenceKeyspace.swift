import Foundation

/// A UserDefaults view whose keys carry an optional profile prefix (`<serverID:userID>/<key>`).
/// A nil scope is the unprefixed space every store used before settings became per profile, which
/// still holds the device values and the migration source.
///
/// It exists so the preference stores keep their `store.set(_:forKey:)` lines unchanged, and so the
/// registry learns about every write in one place: `onWrite` is how a real edit is told apart from a
/// seeded copy (the registry suppresses it while seeding or applying a cloud record).
@MainActor
final class PreferenceKeyspace {
    let defaults: UserDefaults
    private let prefix: String

    var onWrite: ((String) -> Void)?

    init(defaults: UserDefaults, scope: String?) {
        self.defaults = defaults
        self.prefix = scope.map { "\($0)/" } ?? ""
    }

    func fullKey(_ name: String) -> String { prefix + name }

    func set(_ value: Any?, forKey name: String) {
        defaults.set(value, forKey: fullKey(name))
        onWrite?(name)
    }

    func object(forKey name: String) -> Any? { defaults.object(forKey: fullKey(name)) }
    func string(forKey name: String) -> String? { defaults.string(forKey: fullKey(name)) }
    func array(forKey name: String) -> [Any]? { defaults.array(forKey: fullKey(name)) }
}
