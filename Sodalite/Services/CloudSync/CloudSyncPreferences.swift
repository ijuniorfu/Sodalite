import Foundation
import Observation

/// Local-only sync bookkeeping (deliberately never synced itself): enabled flag,
/// adoption state, engine state blob, per-record LWW stamps and CKRecord system
/// field archives, and the monotonic stamp high-water mark.
@Observable
final class CloudSyncPreferences {
    private enum Keys {
        static let enabled = "cloudSync.enabled"
        static let adoptionCompleted = "cloudSync.adoptionCompleted"
        static let accountID = "cloudSync.accountID"
        static let lastSyncAt = "cloudSync.lastSyncAt"
        static let engineState = "cloudSync.engineState"
        static let highestSeenStamp = "cloudSync.highestSeenStamp"
        static let localStamps = "cloudSync.localStamps"
        static let systemFields = "cloudSync.systemFields"
        static let pendingSaves = "cloudSync.pendingSaves"
        static let pendingDeletes = "cloudSync.pendingDeletes"
    }

    private let store: UserDefaults

    var isEnabled: Bool { didSet { store.set(isEnabled, forKey: Keys.enabled) } }
    var adoptionCompleted: Bool { didSet { store.set(adoptionCompleted, forKey: Keys.adoptionCompleted) } }
    var accountID: String? {
        didSet {
            if let accountID { store.set(accountID, forKey: Keys.accountID) }
            else { store.removeObject(forKey: Keys.accountID) }
        }
    }
    var lastSyncAt: Date? {
        didSet {
            if let lastSyncAt { store.set(lastSyncAt.timeIntervalSince1970, forKey: Keys.lastSyncAt) }
            else { store.removeObject(forKey: Keys.lastSyncAt) }
        }
    }
    var engineState: Data? {
        didSet {
            if let engineState { store.set(engineState, forKey: Keys.engineState) }
            else { store.removeObject(forKey: Keys.engineState) }
        }
    }

    private var highestSeenStamp: Date?
    private var localStamps: [String: Double]
    private var systemFieldsByRecord: [String: Data]
    private var pendingSaveNames: [String]
    private var pendingDeleteNames: [String]

    init(store: UserDefaults = .standard) {
        self.store = store
        self.isEnabled = store.object(forKey: Keys.enabled) == nil ? true : store.bool(forKey: Keys.enabled)
        self.adoptionCompleted = store.bool(forKey: Keys.adoptionCompleted)
        self.accountID = store.string(forKey: Keys.accountID)
        self.lastSyncAt = (store.object(forKey: Keys.lastSyncAt) as? Double).map(Date.init(timeIntervalSince1970:))
        self.engineState = store.data(forKey: Keys.engineState)
        self.highestSeenStamp = (store.object(forKey: Keys.highestSeenStamp) as? Double).map(Date.init(timeIntervalSince1970:))
        self.localStamps = (store.dictionary(forKey: Keys.localStamps) as? [String: Double]) ?? [:]
        self.systemFieldsByRecord = (store.dictionary(forKey: Keys.systemFields) as? [String: Data]) ?? [:]
        self.pendingSaveNames = store.stringArray(forKey: Keys.pendingSaves) ?? []
        self.pendingDeleteNames = store.stringArray(forKey: Keys.pendingDeletes) ?? []
    }

    // MARK: Stamps

    /// Issues the next LWW stamp; also raises the high-water mark so two writes
    /// inside the same millisecond still order.
    func nextStamp() -> Date {
        let stamp = CloudSyncMerge.monotonicStamp(now: Date(), highestSeen: highestSeenStamp)
        highestSeenStamp = stamp
        store.set(stamp.timeIntervalSince1970, forKey: Keys.highestSeenStamp)
        return stamp
    }

    /// Records a stamp observed on a remote payload so nextStamp always outranks it.
    func noteRemoteStamp(_ stamp: Date) {
        guard stamp > (highestSeenStamp ?? .distantPast) else { return }
        highestSeenStamp = stamp
        store.set(stamp.timeIntervalSince1970, forKey: Keys.highestSeenStamp)
    }

    func localStamp(for recordName: String) -> Date? {
        localStamps[recordName].map(Date.init(timeIntervalSince1970:))
    }

    func setLocalStamp(_ stamp: Date, for recordName: String) {
        localStamps[recordName] = stamp.timeIntervalSince1970
        store.set(localStamps, forKey: Keys.localStamps)
    }

    // MARK: CKRecord system field archives (avoids oplock conflicts on re-save)

    func systemFields(for recordName: String) -> Data? {
        systemFieldsByRecord[recordName]
    }

    func setSystemFields(_ data: Data, for recordName: String) {
        systemFieldsByRecord[recordName] = data
        store.set(systemFieldsByRecord, forKey: Keys.systemFields)
    }

    func removeRecordCaches(for recordName: String) {
        localStamps.removeValue(forKey: recordName)
        systemFieldsByRecord.removeValue(forKey: recordName)
        store.set(localStamps, forKey: Keys.localStamps)
        store.set(systemFieldsByRecord, forKey: Keys.systemFields)
    }

    /// Drops only the record identity, never the LWW stamp: a save rejected because our identity
    /// was wrong still has to win the merge it was queued for.
    func removeSystemFields(for recordName: String) {
        systemFieldsByRecord.removeValue(forKey: recordName)
        store.set(systemFieldsByRecord, forKey: Keys.systemFields)
    }

    /// Zone resync: every cached identity is suspect, the stamps are not. Keeping the stamps is
    /// what stops a resync from degrading into a cloud-wins adoption.
    func forgetAllSystemFields() {
        systemFieldsByRecord = [:]
        store.removeObject(forKey: Keys.systemFields)
    }

    // MARK: Pending changes stashed while the engine is unavailable

    func stashPendingSave(_ recordName: String) {
        pendingDeleteNames.removeAll { $0 == recordName }
        if !pendingSaveNames.contains(recordName) { pendingSaveNames.append(recordName) }
        store.set(pendingSaveNames, forKey: Keys.pendingSaves)
        store.set(pendingDeleteNames, forKey: Keys.pendingDeletes)
    }

    func stashPendingDelete(_ recordName: String) {
        pendingSaveNames.removeAll { $0 == recordName }
        if !pendingDeleteNames.contains(recordName) { pendingDeleteNames.append(recordName) }
        store.set(pendingSaveNames, forKey: Keys.pendingSaves)
        store.set(pendingDeleteNames, forKey: Keys.pendingDeletes)
    }

    func drainPendingChanges() -> (saves: [String], deletes: [String]) {
        let result = (saves: pendingSaveNames, deletes: pendingDeleteNames)
        pendingSaveNames = []
        pendingDeleteNames = []
        store.removeObject(forKey: Keys.pendingSaves)
        store.removeObject(forKey: Keys.pendingDeletes)
        return result
    }

    // MARK: Resets

    /// Our zone was deleted on the server, so every record we knew about is gone with it and
    /// each cached identity and stamp is meaningless. The engine's own knowledge is deliberately
    /// left alone: it saw the same deletion and rewrites its state itself, and nilling that blob
    /// behind a running engine is how a stale change token outlives the zone it belonged to.
    func resetForZoneRecreation() {
        adoptionCompleted = false
        lastSyncAt = nil
        localStamps = [:]
        systemFieldsByRecord = [:]
        pendingSaveNames = []
        pendingDeleteNames = []
        store.removeObject(forKey: Keys.localStamps)
        store.removeObject(forKey: Keys.systemFields)
        store.removeObject(forKey: Keys.pendingSaves)
        store.removeObject(forKey: Keys.pendingDeletes)
    }

    /// iCloud account switched (or full logout): drop everything tied to the old
    /// account so the next start re-adopts cleanly.
    func resetForAccountChange() {
        resetForZoneRecreation()
        accountID = nil
        engineState = nil
    }

    /// User deleted the cloud zone from Settings: same wipe, but keep accountID.
    func resetForCloudDataDeletion() {
        let account = accountID
        resetForAccountChange()
        accountID = account
    }
}
