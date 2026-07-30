import Foundation
import Testing

/// The veil is a view modifier, so what is worth pinning is its shape: that it blurs, that it
/// replaces the text for VoiceOver rather than only hiding it visually, and that it resolves the
/// user id from AppState instead of the keychain-backed activeUserID (Sodalite#50).
struct SpoilerVeilStructureTests {
    @Test("the veil blurs, relabels for VoiceOver and stays off the keychain")
    func veilShape() throws {
        let source = try sourceFile("Sodalite/Components/SpoilerVeil.swift")
        #expect(source.contains("enum SpoilerVeilStyle"))
        #expect(source.contains("func spoilerVeil("))
        #expect(source.contains(".blur(radius:"))
        #expect(source.contains("eye.slash"))
        #expect(source.contains("spoiler.hidden"))
        #expect(source.contains("accessibilityLabel"))
        #expect(!source.contains("dependencies.activeUserID"))
        #expect(source.contains("appState.activeUser?.id"))
    }

    @Test("the container builds a policy from the preferences and the reveal store")
    func policyFactory() throws {
        let source = try sourceFile("Sodalite/App/Environment/DependencyContainer.swift")
        #expect(source.contains("func spoilerPolicy(userID: String?) -> SpoilerPolicy"))
        #expect(source.contains("appearancePreferences.spoilerProtectionEnabled"))
        #expect(source.contains("spoilerRevealMemory.revealedKeys"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repository.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
