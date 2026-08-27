import Foundation
import Testing
@testable import Sodalite

/// Sodalite#83: the setup screens accept a bare address and let discovery work out scheme and port,
/// so the URL editors have to accept the same text instead of demanding a scheme.
@Suite("Server address resolution")
struct ServerAddressResolutionTests {
    private let resolved = URL(string: "http://192.168.1.10:5055")!

    private func discovery(
        answers: [String: URL],
        delay: Duration = .zero
    ) -> @Sendable (String) async -> URL? {
        { input in
            try? await Task.sleep(for: delay)
            return answers[input]
        }
    }

    @Test("a bare address is resolved to what answered")
    func bareAddressResolves() async {
        let outcome = await ServerAddressResolution.resolve(
            "192.168.1.10",
            discover: discovery(answers: ["192.168.1.10": resolved])
        )
        #expect(outcome == .resolved(resolved))
    }

    @Test("surrounding whitespace reaches discovery trimmed")
    func trimsBeforeDiscovery() async {
        let outcome = await ServerAddressResolution.resolve(
            "  192.168.1.10\n",
            discover: discovery(answers: ["192.168.1.10": resolved])
        )
        #expect(outcome == .resolved(resolved))
    }

    @Test("an empty field clears the slot rather than failing")
    func emptyIsASlot() async {
        #expect(await ServerAddressResolution.resolve("", discover: discovery(answers: [:])) == .empty)
        #expect(await ServerAddressResolution.resolve("   ", discover: discovery(answers: [:])) == .empty)
    }

    /// The slot being edited may live on a network this device cannot see right now, so a complete
    /// URL survives a silent discovery and lands on the save-anyway path.
    @Test("a complete URL nobody answers stays savable")
    func unreachableCompleteURL() async {
        let outcome = await ServerAddressResolution.resolve(
            "https://jellyseerr.example.com",
            discover: discovery(answers: [:])
        )
        #expect(outcome == .unreachable(URL(string: "https://jellyseerr.example.com")!))
    }

    /// Without a scheme there is nothing to save unverified: which of the four candidates the
    /// address meant is exactly what discovery failed to establish.
    @Test("a bare address nobody answers cannot be saved unverified")
    func unresolvedBareAddress() async {
        #expect(await ServerAddressResolution.resolve("192.168.1.10", discover: discovery(answers: [:])) == .unresolved)
        #expect(await ServerAddressResolution.resolve("seerr.example.com:5055", discover: discovery(answers: [:])) == .unresolved)
    }

    @Test("discovery past the budget is treated as no answer")
    func budgetBoundsTheWait() async {
        let outcome = await ServerAddressResolution.resolve(
            "http://192.168.1.10:5055",
            budget: .milliseconds(50),
            discover: discovery(answers: ["http://192.168.1.10:5055": resolved], delay: .seconds(30))
        )
        #expect(outcome == .unreachable(resolved))
    }

    @Test("only http and https can be saved without an answer")
    func completeURLNeedsASchemeWeSpeak() {
        #expect(ServerAddressResolution.completeURL("http://192.168.1.10:8096") != nil)
        #expect(ServerAddressResolution.completeURL("HTTPS://jellyfin.example.com") != nil)
        #expect(ServerAddressResolution.completeURL(" http://192.168.1.10/jellyfin ") != nil)
        #expect(ServerAddressResolution.completeURL("ftp://192.168.1.10") == nil)
        #expect(ServerAddressResolution.completeURL("192.168.1.10:8096") == nil)
        #expect(ServerAddressResolution.completeURL("http://") == nil)
        #expect(ServerAddressResolution.completeURL("jellyfin.example.com") == nil)
    }
}
