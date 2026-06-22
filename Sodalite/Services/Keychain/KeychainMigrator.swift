import Foundation
import os.log
import Security

/// One-shot keychain hygiene at startup, before any keychain reader.
/// Only the pre-entitlement wipe remains. The old JellySeeTV→Sodalite bridge + schema migrations were dead since 0.8.0 (the wipe ran the same launch and deleted everything the bridge copied) and were removed; the flags `Sodalite.didMigrateFromJellySeeTV.v1`, `…ActiveServerToMulti.v1`, `…SharedSessionToTVUser.v1` are no longer read.
enum KeychainMigrator {
    private static let log = Logger(
        subsystem: "de.superuser404.Sodalite",
        category: "KeychainMigrator"
    )

    private static let preEntitlementWipeFlagKey = "Sodalite.didWipePreEntitlementKeychain.v1"

    private static let oldMainService = "de.superuser404.JellySeeTV"
    private static let oldSharedService = "de.superuser404.JellySeeTV.shared"
    private static let newMainService = "de.superuser404.Sodalite"
    private static let newSharedService = "de.superuser404.Sodalite.shared"

    /// Safe to call from any thread; idempotent after the first
    /// successful run per tvOS user.
    static func migrateIfNeeded() {
        wipePreEntitlementKeychainIfNeeded()
    }

    /// One-shot wipe across the four service strings (Sodalite + JellySeeTV, each main + shared), gated by a per-user UserDefaults flag. Pre-`runs-as-current-user` items are device-wide and `SecItemCopyMatching` returns them ahead of per-user writes, masking them ("session swaps when I switch tvOS user"). Wiping forces a one-time re-login into the per-user-isolated bucket.
    static func wipePreEntitlementKeychainIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: preEntitlementWipeFlagKey) else { return }

        var totalDeleted = 0
        let services = [
            newMainService,
            newSharedService,
            oldMainService,
            oldSharedService,
        ]

        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecMatchLimit as String: kSecMatchLimitAll,
                kSecReturnAttributes as String: true,
            ]
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess,
                  let items = result as? [[String: Any]]
            else { continue }

            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String
                else { continue }
                let delete: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                ]
                if SecItemDelete(delete as CFDictionary) == errSecSuccess {
                    totalDeleted += 1
                }
            }
        }

        log.notice("KeychainMigrator: pre-entitlement wipe deleted \(totalDeleted, privacy: .public) items")
        defaults.set(true, forKey: preEntitlementWipeFlagKey)
    }
}
