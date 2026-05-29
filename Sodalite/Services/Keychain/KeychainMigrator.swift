import Foundation
import os.log
import Security

/// One-shot copy of the previous JellySeeTV install's secrets into
/// the new Sodalite namespace. Runs at app startup before any other
/// keychain reader so `restoreSession()` finds the credentials in
/// the new service bucket and the user lands on their library
/// instead of the login screen.
///
/// The bridge works because `Sodalite.entitlements` claims the old
/// keychain access groups (`…JellySeeTV` + `…JellySeeTV.shared`) and
/// app group (`group.de.superuser404.JellySeeTV`) as read-only
/// migration paths, see Phase D.1 of the rename plan. As long as
/// the old JellySeeTV.app is still installed when Sodalite first
/// launches, every secret it ever wrote is reachable here.
///
/// Once the migration flag flips, the migrator is a no-op for the
/// rest of the install's lifetime. After 4–6 weeks the migration
/// access groups can be dropped from the entitlements file
/// entirely (Phase F).
enum KeychainMigrator {
    private static let log = Logger(
        subsystem: "de.superuser404.Sodalite",
        category: "KeychainMigrator"
    )

    private static let migratedFlagKey = "Sodalite.didMigrateFromJellySeeTV.v1"
    private static let activeServerMigratedFlagKey = "Sodalite.didMigrateActiveServerToMulti.v1"
    private static let sharedSessionMigratedFlagKey = "Sodalite.didMigrateSharedSessionToTVUser.v1"
    private static let preEntitlementWipeFlagKey = "Sodalite.didWipePreEntitlementKeychain.v1"

    private static let oldMainService = "de.superuser404.JellySeeTV"
    private static let oldSharedService = "de.superuser404.JellySeeTV.shared"
    private static let newMainService = "de.superuser404.Sodalite"
    private static let newSharedService = "de.superuser404.Sodalite.shared"

    private static let oldAppGroup = "group.de.superuser404.JellySeeTV"
    private static let newAppGroup = "group.de.superuser404.Sodalite"

    private static let oldDeviceIDKey = "JellySeeTV_DeviceID"
    private static let newDeviceIDKey = "Sodalite_DeviceID"

    /// Runs the migration once per install. Safe to call from any
    /// thread; idempotent after the first successful run.
    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard

        // 1. JellySeeTV cross-bundle bridge runs first when the flag is
        // unset. On installs upgrading from JellySeeTV, this copies that
        // app's secrets into Sodalite's service buckets so subsequent
        // steps (and `restoreSession`) see them.
        if !defaults.bool(forKey: migratedFlagKey) {
            let mainCopied = copyAllItems(fromService: oldMainService, toService: newMainService)
            let sharedCopied = copyAllItems(fromService: oldSharedService, toService: newSharedService)
            migrateAppGroupDeviceID()

            // Mark migration done even if no items were found, a fresh
            // install has nothing to copy and shouldn't keep probing on
            // every cold launch.
            defaults.set(true, forKey: migratedFlagKey)
            log.notice("KeychainMigrator finished: main=\(mainCopied, privacy: .public) shared=\(sharedCopied, privacy: .public)")
        }

        // 2. Wipe everything written under the pre-multi-user regime
        // once per tvOS user. Items written before the
        // `runs-as-current-user` entitlement landed shadow per-user
        // writes (they're visible across users), so we delete every
        // residual item and force a clean re-login. The flag is in
        // UserDefaults, which is itself per-user-isolated, so each
        // tvOS user wipes their own bucket exactly once.
        wipePreEntitlementKeychainIfNeeded()

        // 3. Multi-server and shared-session schema migrations. After
        // the wipe these are no-ops (nothing to migrate), but the
        // flags still flip so we don't re-probe on every cold launch.
        // They must NOT be nested inside the JellySeeTV guard because
        // that migration ran months before either schema existed;
        // upgraders from 0.7.0 already have migratedFlagKey == true
        // and would otherwise never reach the new schemas.
        migrateActiveServerToMultiIfNeeded()
        migrateSharedSessionToTVUserSlotIfNeeded()
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

    /// Enumerates every generic password under `fromService` and
    /// writes a copy under `toService`. Existing items at the new
    /// service are left alone, Sodalite's own writes always win
    /// over a stale migration if the user did anything mid-flight.
    @discardableResult
    private static func copyAllItems(fromService: String, toService: String) -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: fromService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            if status != errSecItemNotFound {
                log.notice("KeychainMigrator probe failed: service=\(fromService, privacy: .public) status=\(status, privacy: .public)")
            }
            return 0
        }

        var copied = 0
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data
            else { continue }

            // Don't overwrite, only fill in what's missing. Lets the
            // migrator be re-run later (debug rerun, flag reset)
            // without clobbering a more recent Sodalite write.
            if itemExists(account: account, service: toService) { continue }

            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: toService,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                copied += 1
            } else {
                log.notice("KeychainMigrator copy failed: account=\(account, privacy: .public) status=\(addStatus, privacy: .public)")
            }
        }
        return copied
    }

    private static func itemExists(account: String, service: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// One-shot migration of the pre-multi-server keychain layout:
    /// the old `"activeServer"` slot held one JSON-encoded
    /// JellyfinServer. The new layout uses `knownServers` (an array)
    /// plus `activeServerID` (a pointer). We translate the single
    /// slot into a one-element list and set the pointer to its id.
    /// Per-server keys (accessToken_<id> etc.) are already correctly
    /// scoped and need no migration.
    static func migrateActiveServerToMultiIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: activeServerMigratedFlagKey) else { return }

        let keychain = KeychainService(service: newMainService)

        // Skip cleanly on fresh installs (no old slot to migrate)
        // and on installs that already have the new schema.
        if (try? keychain.loadData(for: KeychainKeys.knownServers)) != nil {
            defaults.set(true, forKey: activeServerMigratedFlagKey)
            return
        }
        guard let blob = try? keychain.loadData(for: "activeServer"),
              let server = try? JSONDecoder().decode(JellyfinServer.self, from: blob)
        else {
            defaults.set(true, forKey: activeServerMigratedFlagKey)
            return
        }

        do {
            let list = try JSONEncoder().encode([server])
            try keychain.save(list, for: KeychainKeys.knownServers)
            try keychain.save(server.id, for: KeychainKeys.activeServerID)
            try? keychain.delete(for: "activeServer")
            log.notice("KeychainMigrator: activeServer -> multi schema (server id=\(server.id, privacy: .public))")
        } catch {
            log.notice("KeychainMigrator: activeServer -> multi failed: \(String(describing: error), privacy: .public)")
            return
        }

        defaults.set(true, forKey: activeServerMigratedFlagKey)
    }

    /// One-shot packing of the pre-tvOS-user-aware shared session into
    /// the new JSON Payload slot. Before the tvOS-multi-user work,
    /// SharedSession wrote three independent keychain accounts
    /// (shared.serverURL, shared.userID, shared.accessToken) in the
    /// shared service bucket. The new format encodes everything into
    /// a single JSON blob at tvOSSession_default. This step reads the
    /// three legacy accounts, encodes them into a Payload that matches
    /// SharedSessionMirror.Payload's Codable shape, writes the blob to
    /// the new slot, then deletes the three legacy accounts so only
    /// the new slot remains.
    static func migrateSharedSessionToTVUserSlotIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: sharedSessionMigratedFlagKey) else { return }

        let sharedService = newSharedService
        let legacyServerURLAccount = "shared.serverURL"
        let legacyUserIDAccount = "shared.userID"
        let legacyAccessTokenAccount = "shared.accessToken"
        let newSlot = "tvOSSession_default"

        // Read the three legacy accounts directly via SecItem. The
        // existing KeychainService is scoped to the main service;
        // legacy SharedSession blobs live in the shared service bucket.
        guard let serverURLString = readSharedLegacyAccount(legacyServerURLAccount, service: sharedService),
              let userIDString = readSharedLegacyAccount(legacyUserIDAccount, service: sharedService),
              let accessTokenString = readSharedLegacyAccount(legacyAccessTokenAccount, service: sharedService)
        else {
            // Nothing to migrate (fresh install) or partially-set
            // legacy state. Mark done so we stop probing on each launch.
            defaults.set(true, forKey: sharedSessionMigratedFlagKey)
            return
        }

        // Skip if the new target slot already has data (prior partial
        // migration or a first-time login that already used the new format).
        if readSharedLegacyAccount(newSlot, service: sharedService) != nil {
            // Still delete the legacy accounts to clean up.
            for account in [legacyServerURLAccount, legacyUserIDAccount, legacyAccessTokenAccount] {
                deleteSharedLegacyAccount(account, service: sharedService)
            }
            defaults.set(true, forKey: sharedSessionMigratedFlagKey)
            return
        }

        // Encode into the new Payload JSON shape. SharedSessionMirror.Payload
        // stores serverURL as String (absoluteString), so we match that exactly.
        struct MigrationPayload: Codable {
            let serverURL: String
            let userID: String
            let accessToken: String
        }
        let payload = MigrationPayload(
            serverURL: serverURLString,
            userID: userIDString,
            accessToken: accessTokenString
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            log.notice("KeychainMigrator: sharedSession payload encode failed")
            return
        }

        // Write to the new slot using the same access-group probing
        // pattern as SharedSessionMirror.save so the TopShelf extension
        // can read the item from the same group.
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sharedService,
            kSecAttrAccount as String: newSlot,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if let group = resolvedSharedAccessGroup(service: sharedService) {
            addQuery[kSecAttrAccessGroup as String] = group
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            log.notice("KeychainMigrator: sharedSession write failed status=\(addStatus, privacy: .public)")
            return
        }

        // Delete the three legacy accounts.
        for account in [legacyServerURLAccount, legacyUserIDAccount, legacyAccessTokenAccount] {
            deleteSharedLegacyAccount(account, service: sharedService)
        }

        log.notice("KeychainMigrator: sharedSession three-account -> tvOSSession_default")
        defaults.set(true, forKey: sharedSessionMigratedFlagKey)
    }

    private static func readSharedLegacyAccount(_ account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    private static func deleteSharedLegacyAccount(_ account: String, service: String) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group = resolvedSharedAccessGroup(service: service) {
            query[kSecAttrAccessGroup as String] = group
        }
        SecItemDelete(query as CFDictionary)
    }

    /// Probes any existing keychain item to extract the team-ID prefix,
    /// then synthesizes the fully-qualified access group for the shared
    /// service. Mirrors the logic in SharedSessionMirror.resolvedAccessGroup.
    /// Returns nil on fresh installs where no keychain items exist yet;
    /// the caller then omits kSecAttrAccessGroup and lets the OS use the
    /// default entitled group.
    private static func resolvedSharedAccessGroup(service: String) -> String? {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(probe as CFDictionary, &item)
        guard status == errSecSuccess,
              let attrs = item as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              let dot = group.firstIndex(of: ".")
        else { return nil }
        let prefix = String(group[..<group.index(after: dot)])
        return prefix + "de.superuser404.Sodalite.shared"
    }

    /// Pulls the TopShelf extension's device id out of the old app
    /// group so Jellyfin's session list keeps the same row instead
    /// of a new "Sodalite Top Shelf" entry appearing alongside the
    /// old one. Same for the main app's device id, which the OLD
    /// JellySeeTV stamped into its own UserDefaults.standard, that
    /// store is sandboxed per app and unreachable from here, so the
    /// only path is via the App Group if the OLD app mirrored it
    /// there. Sodalite's farewell build can do that mirror; if it
    /// hasn't, we just skip and let JellyfinClient generate a fresh
    /// id (Jellyfin shows a duplicate session row, harmless).
    private static func migrateAppGroupDeviceID() {
        guard let oldGroupDefaults = UserDefaults(suiteName: oldAppGroup),
              let newGroupDefaults = UserDefaults(suiteName: newAppGroup)
        else { return }

        // TopShelf-specific id (always lived in the app group).
        if newGroupDefaults.string(forKey: "topShelf.deviceID") == nil,
           let oldShelfID = oldGroupDefaults.string(forKey: "topShelf.deviceID") {
            newGroupDefaults.set(oldShelfID, forKey: "topShelf.deviceID")
        }

        // Main-app device id, only present if the farewell build
        // mirrored it into the app group. UserDefaults.standard from
        // the old app is not reachable from here.
        let standardDefaults = UserDefaults.standard
        if standardDefaults.string(forKey: newDeviceIDKey) == nil,
           let oldMainID = oldGroupDefaults.string(forKey: oldDeviceIDKey) {
            standardDefaults.set(oldMainID, forKey: newDeviceIDKey)
        }
    }
}
