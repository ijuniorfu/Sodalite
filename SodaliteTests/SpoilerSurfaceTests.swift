import Foundation
import Testing

/// Sodalite#50 touches one line per surface. These pin that each of those lines is still there,
/// since a dropped veil is invisible in every other test: the screen simply shows the spoiler.
struct SpoilerSurfaceTests {
    @Test("episode card art and synopsis are veiled")
    func episodeRowComponentsVeiled() throws {
        let source = try sourceFile("Sodalite/Features/Detail/EpisodeRowComponents.swift")
        #expect(source.contains(".spoilerVeil(for: episode, style: .image)"))
        #expect(source.contains(".spoilerVeil(for: episode, style: .text)"))
        #expect(source.contains("let episode: JellyfinItem"))
    }

    @Test("the synopsis box reveals before it expands")
    func synopsisTwoStep() throws {
        let source = try sourceFile("Sodalite/Features/Detail/EpisodeRowComponents.swift")
        #expect(source.contains("SpoilerReveal.reveal(episode"))
    }

    @Test("the episode context menu offers a reveal for art-only spoilers")
    func contextMenuReveal() throws {
        let source = try sourceFile("Sodalite/Features/Detail/SeriesDetailView.swift")
        #expect(source.contains("spoiler.reveal"))
        #expect(source.contains("SpoilerReveal.reveal(episode"))
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
