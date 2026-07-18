import Foundation
import Testing
@testable import Sodalite

@Suite("Dual-URL prompt latch")
struct DualURLPromptLatchTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "DualURLPromptLatchTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test("unset server has not been offered")
    func unset() {
        let d = freshDefaults()
        #expect(DualURLPromptLatch.hasOffered(serverID: "srv-1", defaults: d) == false)
    }

    @Test("marking sets the latch, and it is idempotent")
    func mark() {
        let d = freshDefaults()
        DualURLPromptLatch.markOffered(serverID: "srv-1", defaults: d)
        DualURLPromptLatch.markOffered(serverID: "srv-1", defaults: d)
        #expect(DualURLPromptLatch.hasOffered(serverID: "srv-1", defaults: d))
    }

    @Test("latch is isolated per server id")
    func isolation() {
        let d = freshDefaults()
        DualURLPromptLatch.markOffered(serverID: "srv-1", defaults: d)
        #expect(DualURLPromptLatch.hasOffered(serverID: "srv-1", defaults: d))
        #expect(DualURLPromptLatch.hasOffered(serverID: "srv-2", defaults: d) == false)
    }
}
