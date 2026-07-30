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

    @Test("the shared media card veils episode art")
    func mediaCardVeiled() throws {
        let source = try sourceFile("Sodalite/Components/MediaCard.swift")
        #expect(source.contains(".spoilerVeil(for: item, style: .image)"))
    }

    @Test("the expandable text box takes an optional spoiler item and reveals first")
    func expandableTextBoxTwoStep() throws {
        let source = try sourceFile("Sodalite/Components/ExpandableTextBox.swift")
        #expect(source.contains("var spoilerItem: JellyfinItem?"))
        #expect(source.contains("SpoilerReveal.reveal("))
    }

    @Test("both detail heroes pass their item to the text box")
    func detailHeroesPassItem() throws {
        let movie = try sourceFile("Sodalite/Features/Detail/MovieDetailView.swift")
        #expect(movie.contains("spoilerItem: vm.item"))
        let series = try sourceFile("Sodalite/Features/Detail/SeriesDetailView.swift")
        #expect(series.contains("spoilerItem: displayItem"))
    }

    @Test("a veiled episode never paints its own backdrop full bleed")
    func backdropFallsBackToSeries() throws {
        let service = try sourceFile("Sodalite/Services/Jellyfin/JellyfinImageService.swift")
        #expect(service.contains("func parentBackdropURL("))
        let series = try sourceFile("Sodalite/Features/Detail/SeriesDetailView.swift")
        #expect(series.contains("parentBackdropURL(for: episode)"))
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
