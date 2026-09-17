import Foundation
import Testing
@testable import Sodalite

@Suite("CloudSync profile record names")
struct CloudSyncProfileRecordTests {
    private let key = ProfileKey(serverID: "0f3a9c21", userID: "4b8e77aa")

    @Test func namesRoundTripForEveryKind() {
        for kind in ProfileRecordKind.allCases {
            let name = CloudSyncRecordName.profile(kind, key)
            #expect(name == "profile-\(kind.rawValue)-0f3a9c21:4b8e77aa")
            let parsed = CloudSyncRecordName.profileRecord(fromRecordName: name)
            #expect(parsed?.kind == kind)
            #expect(parsed?.key == key)
        }
    }

    @Test func dashedIdsStillParse() {
        let dashed = ProfileKey(serverID: "a-b-c", userID: "d-e")
        let parsed = CloudSyncRecordName.profileRecord(fromRecordName: CloudSyncRecordName.profile(.home, dashed))
        #expect(parsed?.key == dashed)
        #expect(parsed?.kind == .home)
    }

    /// The record type decides the Production schema. A profile record under any type other than
    /// the deployed SyncSettingsStore would fail on every TestFlight and App Store device.
    @Test func profileRecordsUseTheSettingsType() {
        #expect(CloudSyncRecordName.recordType(forRecordName: CloudSyncRecordName.profile(.playback, key)) == CloudSyncRecordType.settings)
        #expect(CloudSyncRecordName.recordType(forRecordName: CloudSyncRecordName.settings(.auth)) == CloudSyncRecordType.settings)
        #expect(CloudSyncRecordName.recordType(forRecordName: CloudSyncRecordName.server(id: "s")) == CloudSyncRecordType.server)
        #expect(CloudSyncRecordName.recordType(forRecordName: CloudSyncRecordName.securitySingleton) == CloudSyncRecordType.security)
    }

    /// What the dispatch in a pre-change build asks of a record name. None of its three branches may
    /// claim a profile record, or an older build would decode it as something it is not.
    @Test func thePreChangeDispatchIgnoresProfileRecords() {
        for kind in ProfileRecordKind.allCases {
            let name = CloudSyncRecordName.profile(kind, key)
            #expect(CloudSyncRecordName.serverID(fromRecordName: name) == nil)
            #expect(CloudSyncRecordName.storeKey(fromRecordName: name) == nil)
            #expect(name != CloudSyncRecordName.securitySingleton)
        }
    }

    @Test func unrelatedNamesAreNotProfileRecords() {
        #expect(CloudSyncRecordName.profileRecord(fromRecordName: "settings-playback") == nil)
        #expect(CloudSyncRecordName.profileRecord(fromRecordName: "profile-bogus-s:u") == nil)
        #expect(CloudSyncRecordName.profileRecord(fromRecordName: "profile-playback-nocolon") == nil)
    }
}
