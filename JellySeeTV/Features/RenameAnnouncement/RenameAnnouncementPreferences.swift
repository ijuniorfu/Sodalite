import Foundation

/// One-shot UserDefaults flag that says the user has actively
/// migrated to Sodalite. Once it flips true, the rename modal
/// stays out of the way for the rest of this install's life.
///
/// Until then, every cold launch of JellySeeTV shows the modal —
/// the migration window is short (a few weeks until soft-sunset)
/// and the cost of a daily reminder is low compared to the cost
/// of someone silently sticking on the old app forever.
enum RenameAnnouncementPreferences {
    private static let storeKey = "rename.userHasMigrated.v1"

    static var hasMigrated: Bool {
        UserDefaults.standard.bool(forKey: storeKey)
    }

    /// Called from the modal's "I've already migrated" CTA. Stamps
    /// the flag so the rename sheet never shows again on this install.
    static func markMigrated() {
        UserDefaults.standard.set(true, forKey: storeKey)
    }
}
