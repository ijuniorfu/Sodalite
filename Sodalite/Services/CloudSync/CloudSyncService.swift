import CloudKit
import Foundation
import Observation

enum CloudSyncStatus: Equatable {
    case disabled
    case noAccount
    case active(lastSyncAt: Date?)
    case error(String)
}

protocol CloudSyncServiceProtocol: AnyObject {
    var status: CloudSyncStatus { get }
    var isEnabled: Bool { get }
    func start()
    func setEnabled(_ enabled: Bool)
    func fetchNow() async
    func markServerDirty(serverID: String)
    func markServerDeleted(serverID: String)
    func markSettingsDirty(_ key: CloudSyncStoreKey)
    func markSecurityDirty()
    func markSecurityDeleted()
    func pushLocalSettingsToAllDevices()
    func deleteCloudDataAndDisable() async
    func handleFullLogout()
}

/// Owns the CKSyncEngine on the private database. All state and delegate work is
/// MainActor (project default isolation); the async delegate requirements hop here.
@Observable
final class CloudSyncService: CloudSyncServiceProtocol {
    static let containerID = "iCloud.de.superuser404.Sodalite"
    static let zoneName = "SodaliteSync"
    static let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    private static let payloadKey = "payload"

    private(set) var status: CloudSyncStatus = .disabled
    var isEnabled: Bool { preferences.isEnabled }

    private unowned let dependencies: DependencyContainer
    let preferences: CloudSyncPreferences
    private var engine: CKSyncEngine?
    private var startInFlight = false
    private var debounceTasks: [CloudSyncStoreKey: Task<Void, Never>] = [:]
    /// Last snapshot uploaded or applied per store, to skip observation echoes.
    private var lastSettingsSnapshot: [CloudSyncStoreKey: SettingsSyncPayload] = [:]
    private var observers: [NSObjectProtocol] = []

    init(dependencies: DependencyContainer, preferences: CloudSyncPreferences = CloudSyncPreferences()) {
        self.dependencies = dependencies
        self.preferences = preferences
    }

    // MARK: Lifecycle

    func start() {
        guard preferences.isEnabled else { status = .disabled; return }
        guard engine == nil, !startInFlight else { return }
        startInFlight = true
        observeAccountChanges()
        observeSettingsStores()
        observeHomeConfigChanges()
        Task { await startEngine() }
    }

    func setEnabled(_ enabled: Bool) {
        preferences.isEnabled = enabled
        if enabled {
            start()
        } else {
            teardownEngine()
            status = .disabled
        }
    }

    private func teardownEngine() {
        engine = nil
        startInFlight = false
        for task in debounceTasks.values { task.cancel() }
        debounceTasks = [:]
    }

    private func startEngine() async {
        defer { startInFlight = false }
        do {
            let container = CKContainer(identifier: Self.containerID)
            guard try await container.accountStatus() == .available else {
                status = .noAccount
                return
            }
            let accountID = try await container.userRecordID().recordName
            if let stored = preferences.accountID, stored != accountID {
                preferences.resetForAccountChange()
            }
            preferences.accountID = accountID

            var config = CKSyncEngine.Configuration(
                database: container.privateCloudDatabase,
                stateSerialization: decodeEngineState(),
                delegate: self
            )
            config.automaticallySync = true
            let engine = CKSyncEngine(config)
            self.engine = engine
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            status = .active(lastSyncAt: preferences.lastSyncAt)

            if !preferences.adoptionCompleted {
                try await engine.fetchChanges()
                completeAdoption()
            }
        } catch {
            status = .error(error.localizedDescription)
            LogTap.shared.note("[CloudSync] start failed: \(error)")
        }
    }

    /// Uploads everything local that adoption's fetch did not already reconcile,
    /// then latches the adoption flag.
    private func completeAdoption() {
        for server in dependencies.listKnownServers() {
            markServerDirty(serverID: server.id)
        }
        for key in CloudSyncStoreKey.allCases {
            // Only upload stores the cloud did not already win at adoption.
            if preferences.localStamp(for: CloudSyncRecordName.settings(key)) == nil {
                markSettingsDirty(key)
            }
        }
        if preferences.localStamp(for: CloudSyncRecordName.securitySingleton) == nil,
           dependencies.isGuardianPINSet() {
            markSecurityDirty()
        }
        preferences.adoptionCompleted = true
        LogTap.shared.note("[CloudSync] adoption complete")
    }

    func fetchNow() async {
        guard let engine else { return }
        try? await engine.fetchChanges()
    }

    // MARK: Dirty marking (called from DependencyContainer mutation hooks)

    func markServerDirty(serverID: String) {
        guard preferences.isEnabled else { return }
        let name = CloudSyncRecordName.server(id: serverID)
        preferences.setLocalStamp(preferences.nextStamp(), for: name)
        addPendingSave(recordName: name)
    }

    func markServerDeleted(serverID: String) {
        guard preferences.isEnabled else { return }
        let name = CloudSyncRecordName.server(id: serverID)
        preferences.removeRecordCaches(for: name)
        engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID(name))])
    }

    func markSettingsDirty(_ key: CloudSyncStoreKey) {
        guard preferences.isEnabled else { return }
        let name = CloudSyncRecordName.settings(key)
        preferences.setLocalStamp(preferences.nextStamp(), for: name)
        addPendingSave(recordName: name)
    }

    func markSecurityDirty() {
        guard preferences.isEnabled else { return }
        preferences.setLocalStamp(preferences.nextStamp(), for: CloudSyncRecordName.securitySingleton)
        addPendingSave(recordName: CloudSyncRecordName.securitySingleton)
    }

    func markSecurityDeleted() {
        guard preferences.isEnabled else { return }
        preferences.removeRecordCaches(for: CloudSyncRecordName.securitySingleton)
        engine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID(CloudSyncRecordName.securitySingleton))])
    }

    /// Manual push: re-stamp every settings store so THIS device wins LWW
    /// everywhere until the next change on any device. Settings only, never
    /// server records (those would clobber newer remote credential changes).
    func pushLocalSettingsToAllDevices() {
        for key in CloudSyncStoreKey.allCases {
            lastSettingsSnapshot[key] = dependencies.collectSettingsPayload(key, stamp: .distantPast)
            markSettingsDirty(key)
        }
        LogTap.shared.note("[CloudSync] manual settings push queued")
    }

    func deleteCloudDataAndDisable() async {
        if let engine {
            engine.state.add(pendingDatabaseChanges: [.deleteZone(Self.zoneID)])
            try? await engine.sendChanges()
        }
        preferences.isEnabled = false
        preferences.resetForCloudDataDeletion()
        teardownEngine()
        status = .disabled
        LogTap.shared.note("[CloudSync] cloud data deleted, sync disabled")
    }

    /// Full local logout: stop syncing, keep cloud data intact (no multi-device
    /// wipe from one logout). Re-enabling later re-adopts from the cloud.
    func handleFullLogout() {
        preferences.isEnabled = false
        preferences.resetForCloudDataDeletion()
        teardownEngine()
        status = .disabled
    }

    // MARK: Observation of local changes

    private func observeAccountChanges() {
        let observer = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.preferences.isEnabled else { return }
                self.teardownEngine()
                self.start()
            }
        }
        observers.append(observer)
    }

    private func observeHomeConfigChanges() {
        let observer = NotificationCenter.default.addObserver(
            forName: .homeConfigDidChange, object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self, !self.dependencies.isApplyingCloudChanges else { return }
                if let serverID = self.dependencies.activeServer?.id {
                    self.markServerDirty(serverID: serverID)
                }
            }
        }
        observers.append(observer)
    }

    private func observeSettingsStores() {
        for key in CloudSyncStoreKey.allCases { armObservation(for: key) }
    }

    private func armObservation(for key: CloudSyncStoreKey) {
        withObservationTracking {
            // Touch every synced property so any change re-arms us.
            _ = dependencies.collectSettingsPayload(key, stamp: .distantPast)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleSettingsUpload(key)
                self.armObservation(for: key)
            }
        }
    }

    private func scheduleSettingsUpload(_ key: CloudSyncStoreKey) {
        debounceTasks[key]?.cancel()
        debounceTasks[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.uploadSettingsIfChanged(key)
        }
    }

    private func uploadSettingsIfChanged(_ key: CloudSyncStoreKey) {
        guard preferences.isEnabled, !dependencies.isApplyingCloudChanges else { return }
        let snapshot = dependencies.collectSettingsPayload(key, stamp: .distantPast)
        if lastSettingsSnapshot[key] == snapshot { return }
        lastSettingsSnapshot[key] = snapshot
        markSettingsDirty(key)
    }

    // MARK: Record building / applying

    private func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: Self.zoneID)
    }

    private func recordType(forRecordName name: String) -> CKRecord.RecordType {
        if CloudSyncRecordName.serverID(fromRecordName: name) != nil { return CloudSyncRecordType.server }
        if CloudSyncRecordName.storeKey(fromRecordName: name) != nil { return CloudSyncRecordType.settings }
        return CloudSyncRecordType.security
    }

    private func addPendingSave(recordName: String) {
        engine?.state.add(pendingRecordZoneChanges: [.saveRecord(recordID(recordName))])
    }

    private func collectPayloadData(recordName: String) -> Data? {
        let stamp = preferences.localStamp(for: recordName) ?? preferences.nextStamp()
        if let serverID = CloudSyncRecordName.serverID(fromRecordName: recordName) {
            guard let payload = dependencies.collectServerPayload(serverID: serverID, stamp: stamp) else { return nil }
            return try? JSONEncoder().encode(payload)
        }
        if let key = CloudSyncRecordName.storeKey(fromRecordName: recordName) {
            return try? dependencies.collectSettingsPayload(key, stamp: stamp).encoded()
        }
        guard let payload = dependencies.collectSecurityPayload(stamp: stamp) else { return nil }
        return try? JSONEncoder().encode(payload)
    }

    private func buildRecord(recordName: String) -> CKRecord? {
        guard let payloadData = collectPayloadData(recordName: recordName) else {
            // Nothing local anymore (e.g. server removed while queued): drop the save.
            engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID(recordName))])
            return nil
        }
        let record: CKRecord
        if let archived = preferences.systemFields(for: recordName),
           let restored = Self.decodeSystemFields(archived) {
            record = restored
        } else {
            record = CKRecord(recordType: recordType(forRecordName: recordName), recordID: recordID(recordName))
        }
        record.encryptedValues[Self.payloadKey] = payloadData
        return record
    }

    private func applyRemoteRecord(_ record: CKRecord) {
        guard let data = record.encryptedValues[Self.payloadKey] as? Data else { return }
        let name = record.recordID.recordName
        preferences.setSystemFields(Self.encodeSystemFields(record), for: name)
        let adopting = !preferences.adoptionCompleted

        if let serverID = CloudSyncRecordName.serverID(fromRecordName: name) {
            guard let cloud = try? JSONDecoder().decode(ServerSyncPayload.self, from: data) else { return }
            preferences.noteRemoteStamp(cloud.updatedAt)
            if adopting, let local = dependencies.collectServerPayload(serverID: serverID, stamp: .distantPast) {
                let merged = CloudSyncMerge.adoptServerPayload(local: local, cloud: cloud, stamp: preferences.nextStamp())
                dependencies.applyServerPayload(merged)
                preferences.setLocalStamp(merged.updatedAt, for: name)
                if merged != cloud { addPendingSave(recordName: name) }
            } else {
                let localStamp = preferences.localStamp(for: name) ?? .distantPast
                if CloudSyncMerge.remoteWins(localUpdatedAt: localStamp, remoteUpdatedAt: cloud.updatedAt) || adopting {
                    dependencies.applyServerPayload(cloud)
                    preferences.setLocalStamp(cloud.updatedAt, for: name)
                } else {
                    addPendingSave(recordName: name)
                }
            }
        } else if let key = CloudSyncRecordName.storeKey(fromRecordName: name) {
            guard let cloud = try? SettingsSyncPayload.decode(data, key: key) else { return }
            preferences.noteRemoteStamp(cloud.updatedAt)
            let localStamp = preferences.localStamp(for: name) ?? .distantPast
            if adopting || CloudSyncMerge.remoteWins(localUpdatedAt: localStamp, remoteUpdatedAt: cloud.updatedAt) {
                dependencies.applySettingsPayload(cloud)
                lastSettingsSnapshot[key] = cloud.restamped(.distantPast)
                preferences.setLocalStamp(cloud.updatedAt, for: name)
            } else {
                addPendingSave(recordName: name)
            }
        } else if name == CloudSyncRecordName.securitySingleton {
            guard let cloud = try? JSONDecoder().decode(SecuritySyncPayload.self, from: data) else { return }
            preferences.noteRemoteStamp(cloud.updatedAt)
            let localStamp = preferences.localStamp(for: name) ?? .distantPast
            if adopting || CloudSyncMerge.remoteWins(localUpdatedAt: localStamp, remoteUpdatedAt: cloud.updatedAt) {
                dependencies.applySecurityPayload(cloud)
                preferences.setLocalStamp(cloud.updatedAt, for: name)
            } else {
                addPendingSave(recordName: name)
            }
        }
    }

    private func applyRemoteDeletion(recordName: String) {
        preferences.removeRecordCaches(for: recordName)
        if let serverID = CloudSyncRecordName.serverID(fromRecordName: recordName) {
            dependencies.applyRemoteServerDeletion(serverID: serverID)
        } else if recordName == CloudSyncRecordName.securitySingleton {
            dependencies.applyRemoteSecurityDeletion()
        }
        // Settings records are never deleted remotely; ignore anything else.
    }

    // MARK: System field + engine state codecs

    private static func encodeSystemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        return CKRecord(coder: unarchiver)
    }

    private func decodeEngineState() -> CKSyncEngine.State.Serialization? {
        guard let data = preferences.engineState else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudSyncService: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            preferences.engineState = try? JSONEncoder().encode(update.stateSerialization)

        case .accountChange(let change):
            switch change.changeType {
            case .signOut, .switchAccounts:
                preferences.resetForAccountChange()
                teardownEngine()
                status = .noAccount
            default:
                break
            }

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID.zoneName == Self.zoneName {
                // Zone deleted externally (user cleared iCloud data in Settings):
                // recreate and re-upload the local state.
                LogTap.shared.note("[CloudSync] zone deleted remotely, re-uploading")
                preferences.resetForCloudDataDeletion()
                preferences.isEnabled = true
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                completeAdoption()
            }

        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                applyRemoteRecord(modification.record)
            }
            for deletion in changes.deletions {
                applyRemoteDeletion(recordName: deletion.recordID.recordName)
            }
            preferences.lastSyncAt = Date()
            status = .active(lastSyncAt: preferences.lastSyncAt)
            NotificationCenter.default.post(name: .cloudSyncDidApplyChanges, object: nil)

        case .sentRecordZoneChanges(let sent):
            for saved in sent.savedRecords {
                preferences.setSystemFields(Self.encodeSystemFields(saved), for: saved.recordID.recordName)
            }
            for failure in sent.failedRecordSaves {
                handleSaveFailure(failure, syncEngine: syncEngine)
            }
            if !sent.savedRecords.isEmpty {
                preferences.lastSyncAt = Date()
                status = .active(lastSyncAt: preferences.lastSyncAt)
            }

        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        // Materialize records on the MainActor up front: the recordProvider closure
        // below is @Sendable (CKSyncEngine may invoke it off-actor), so it cannot
        // call the MainActor-isolated buildRecord itself.
        let built: [CKRecord.ID: CKRecord] = pending.reduce(into: [:]) { result, change in
            if case .saveRecord(let recordID) = change, let record = buildRecord(recordName: recordID.recordName) {
                result[recordID] = record
            }
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            built[recordID]
        }
    }

    private func handleSaveFailure(
        _ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
        syncEngine: CKSyncEngine
    ) {
        let recordName = failure.record.recordID.recordName
        let ckError = failure.error
        switch ckError.code {
        case .serverRecordChanged:
            guard let serverRecord = ckError.serverRecord else { return }
            // Adopt the server's system fields, then LWW: apply theirs if newer,
            // else re-queue ours (now based on their record, so the save sticks).
            preferences.setSystemFields(Self.encodeSystemFields(serverRecord), for: recordName)
            applyRemoteRecord(serverRecord)
        case .zoneNotFound:
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            addPendingSave(recordName: recordName)
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            addPendingSave(recordName: recordName)
        default:
            LogTap.shared.note("[CloudSync] save failed \(recordName): \(ckError.code.rawValue)")
        }
    }
}
