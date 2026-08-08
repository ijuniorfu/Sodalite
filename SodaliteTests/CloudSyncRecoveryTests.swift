import CloudKit
import Foundation
import Testing
@testable import Sodalite

@Suite("CloudSync failure recovery policy")
struct CloudSyncRecoveryTests {

    private static let zoneID = CKRecordZone.ID(zoneName: "SodaliteSync", ownerName: CKCurrentUserDefaultName)

    private static func recordID(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private static func serverRecord(_ name: String) -> CKRecord {
        CKRecord(recordType: "SyncSettingsStore", recordID: recordID(name))
    }

    @Test("a conflict CloudKit answers with its own record is merged, not resynced")
    func conflictWithServerRecordMerges() {
        let error = CKError(
            .serverRecordChanged,
            userInfo: [CKRecordChangedErrorServerRecordKey: Self.serverRecord("settings-playback")]
        )
        #expect(CloudSyncRecovery.saveAction(for: error) == .adoptServerRecord)
    }

    /// The reported defect: every settings record came back "record to insert already exists",
    /// which CloudKit reports without a server record. Merging is impossible there, and leaving
    /// it alone means the record can never be saved again.
    @Test("a conflict without a server record resyncs the zone")
    func insertConflictResyncs() {
        #expect(CloudSyncRecovery.saveAction(for: CKError(.serverRecordChanged)) == .resyncZone)
    }

    @Test("an expired change token resyncs the zone")
    func expiredTokenResyncs() {
        #expect(CloudSyncRecovery.fetchAction(for: CKError(.changeTokenExpired)) == .resyncZone)
        #expect(CloudSyncRecovery.fetchAction(for: CKError(.networkUnavailable)) == .report)
    }

    @Test("a record the server no longer has is re-inserted, not resynced")
    func unknownItemReinserts() {
        #expect(CloudSyncRecovery.saveAction(for: CKError(.unknownItem)) == .reinsert)
    }

    @Test("a missing zone is recreated")
    func missingZoneIsRecreated() {
        #expect(CloudSyncRecovery.saveAction(for: CKError(.zoneNotFound)) == .recreateZone)
        #expect(CloudSyncRecovery.saveAction(for: CKError(.userDeletedZone)) == .recreateZone)
    }

    @Test("transient failures only re-queue")
    func transientFailuresRetry() {
        for code in [CKError.Code.networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy] {
            #expect(CloudSyncRecovery.saveAction(for: CKError(code)) == .retry)
        }
    }

    @Test("quota is surfaced, anything else is only reported")
    func quotaSurfacesAndTheRestReports() {
        #expect(CloudSyncRecovery.saveAction(for: CKError(.quotaExceeded)) == .surfaceQuota)
        #expect(CloudSyncRecovery.saveAction(for: CKError(.permissionFailure)) == .report)
    }

    /// The reported defect: every record came back `Invalid Arguments (12/2006)`, "Cannot create
    /// new type SyncSettingsStore in production schema". The request is malformed for the server
    /// as sent, so the identical retry it used to get can only fail identically.
    @Test("a request the server rejects as invalid is surfaced, not retried")
    func invalidArgumentsSurfaces() {
        #expect(CloudSyncRecovery.saveAction(for: CKError(.invalidArguments)) == .surfaceRejection)
    }

    /// A whole batch that fails carries its per-record errors only in the partial error, so
    /// unpacking it is what lets the recovery above run at all.
    @Test("per-record errors are unpacked from a failed batch")
    func partialErrorsAreUnpacked() {
        let failing = Self.recordID("settings-spoilerReveals")
        let batch = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [failing: CKError(.serverRecordChanged)]
        ])
        let unpacked = CloudSyncRecovery.partialSaveErrors(in: batch)
        #expect(unpacked.count == 1)
        #expect(unpacked[failing]?.code == .serverRecordChanged)
        #expect(unpacked[failing].map(CloudSyncRecovery.saveAction(for:)) == .resyncZone)
    }

    @Test("a non-CloudKit error unpacks to nothing rather than throwing")
    func nonCloudKitErrorUnpacksEmpty() {
        let error = NSError(domain: "test", code: 1)
        #expect(CloudSyncRecovery.partialSaveErrors(in: error).isEmpty)
        #expect(CloudSyncRecovery.describe(error) == error.localizedDescription)
    }

    /// "Failed to send changes" alone is what the status row used to be reduced to; the record
    /// level message underneath is the part that says what actually went wrong.
    @Test("a batch failure is described with the error underneath it")
    func batchFailureNamesTheUnderlyingError() {
        let batch = CKError(.partialFailure, userInfo: [
            CKPartialErrorsByItemIDKey: [Self.recordID("settings-auth"): CKError(.serverRecordChanged)]
        ])
        let described = CloudSyncRecovery.describe(batch)
        #expect(described.contains(CKError(.serverRecordChanged).localizedDescription))
        #expect(described != batch.localizedDescription)
    }
}
