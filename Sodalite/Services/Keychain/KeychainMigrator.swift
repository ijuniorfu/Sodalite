import Foundation
import os.log
import Security

/// One-shot keychain hygiene at app startup, before any other
/// keychain reader.
///
/// Historical note (Phase F executed): this type used to carry the
/// JellySeeTV -> Sodalite rename bridge (cross-service item copies,
/// app-group device-id migration) plus two schema migrations
/// (single-server -> multi-server layout, three-account shared
/// session -> tvOS-user JSON slot). All of those were dead weight
/// since 0.8.0: the pre-entitlement wipe below runs in the same
/// launch and deleted everything the bridge had just copied, so the
/// migrations could never restore anything. The bridge code and the
/// JellySeeTV entitlement claims have been removed; only the wipe
/// remains. The historical UserDefaults flags
/// (`Sodalite.didMigrateFromJellySeeTV.v1`,
/// `Sodalite.didMigrateActiveServerToMulti.v1`,
/// `Sodalite.didMigrateSharedSessionToTVUser.v1`) are simply no
/// longer read.
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

    /// One-shot wipe of every keychain item across the four service
    /// strings Sodalite has ever used (main + shared + JellySeeTV
    /// main + shared). Gated by a per-user UserDefaults flag.
    ///
    /// Items written before `com.apple.developer.user-management =
    /// runs-as-current-user` landed in a pre-multi-user regime, where
    /// they're visible across every tvOS user on the device. Once the
    /// entitlement is in place, items written under it land in the
    /// running user's isolated bucket, but `SecItemCopyMatching` still
    /// returns the pre-regime items first when present, masking the
    /// per-user writes and producing the "session swaps when I switch
    /// tvOS user" symptom.
    ///
    /// Wiping forces every user to log in once on the next launch.
    /// Their session then lands in the per-user-isolated bucket
    /// (enforced by `kSecUseUserIndependentKeychain = false` in
    /// `KeychainService` and `SharedSessionMirror`), and subsequent
    /// user switches stop bleeding sessions.
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
