import Foundation
import Observation

/// Persistent binding between a tvOS system user (as reported by
/// TVUserContext.currentUserID) and a Sodalite (server, Jellyfin
/// profile) tuple. Mappings get auto-recorded the first time a tvOS
/// user successfully signs into a profile, and can be overridden
/// manually from the Apple TV Profile settings sub-screen.
struct TVProfileMapping: Codable, Sendable, Equatable {
    let serverID: String
    let jellyfinUserID: String
}

/// UserDefaults-backed store for `[tvUserID: TVProfileMapping]`.
/// The whole table lives behind a single JSON-encoded key so reads
/// and writes are atomic. Not keychain-backed: the table contains
/// only identifiers, no tokens or other secrets, and we want it to
/// be syncable later via iCloud KVS without a security review.
@Observable
@MainActor
final class TVProfileMappings {

    private enum Keys {
        static let mappings = "tvOS.profileMappings"
    }

    private let store: UserDefaults
    private(set) var allMappings: [String: TVProfileMapping] = [:]

    init(store: UserDefaults = .standard) {
        self.store = store
        self.allMappings = Self.load(from: store)
    }

    /// Returns the mapping for the given tvOS user identifier, or
    /// nil if none has been recorded yet.
    func mapping(for tvUserID: String) -> TVProfileMapping? {
        allMappings[tvUserID]
    }

    /// Upserts a mapping. Passing nil removes the entry for that
    /// tvOS user. Re-recording an identical mapping is a no-op
    /// (auto-record paths call this repeatedly and shouldn't churn
    /// the disk on every login).
    func setMapping(_ mapping: TVProfileMapping?, for tvUserID: String) {
        if let mapping {
            if allMappings[tvUserID] == mapping { return }
            allMappings[tvUserID] = mapping
        } else {
            if allMappings[tvUserID] == nil { return }
            allMappings.removeValue(forKey: tvUserID)
        }
        persist()
    }

    /// Removes every mapping that points at the given server. Called
    /// when a server is removed from the multi-server schema.
    func removeMappings(forServer serverID: String) {
        let filtered = allMappings.filter { $0.value.serverID != serverID }
        if filtered.count == allMappings.count { return }
        allMappings = filtered
        persist()
    }

    /// Removes a single (server, user) mapping. Called when a
    /// remembered user is forgotten from the profile picker.
    func removeMapping(forUser userID: String, on serverID: String) {
        let filtered = allMappings.filter {
            !($0.value.serverID == serverID && $0.value.jellyfinUserID == userID)
        }
        if filtered.count == allMappings.count { return }
        allMappings = filtered
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(allMappings) else { return }
        store.set(data, forKey: Keys.mappings)
    }

    private static func load(from store: UserDefaults) -> [String: TVProfileMapping] {
        guard let data = store.data(forKey: Keys.mappings) else { return [:] }
        return (try? JSONDecoder().decode([String: TVProfileMapping].self, from: data)) ?? [:]
    }
}
