import Foundation
import Observation

/// Binds a tvOS system user (TVUserContext.currentUserID) to a Sodalite (server, Jellyfin profile) tuple. Auto-recorded on first sign-in, overridable from the Apple TV Profile settings.
struct TVProfileMapping: Codable, Sendable, Equatable {
    let serverID: String
    let jellyfinUserID: String
}

/// UserDefaults store for `[tvUserID: TVProfileMapping]`, one JSON key for atomic R/W. Not keychain-backed: only IDs, and intended for later iCloud KVS sync.
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

    func mapping(for tvUserID: String) -> TVProfileMapping? {
        allMappings[tvUserID]
    }

    /// Upserts (nil removes). Re-recording an identical mapping is a no-op so repeated auto-record calls don't churn disk.
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

    /// Called when a server is removed from the multi-server schema.
    func removeMappings(forServer serverID: String) {
        let filtered = allMappings.filter { $0.value.serverID != serverID }
        if filtered.count == allMappings.count { return }
        allMappings = filtered
        persist()
    }

    /// Called when a remembered user is forgotten from the profile picker.
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
