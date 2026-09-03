import Testing
@testable import Sodalite

/// The one spelling of a season/episode line, `S1, E5 · Title`. Pinned here because the format is
/// the point of the helper: every surface that used to hand-roll it drifted into its own dialect.
@MainActor
struct EpisodeMetadataFormatterTests {

    // MARK: - Bare token

    @Test("both numbers join with a comma")
    func seasonAndEpisode() {
        #expect(EpisodeMetadataFormatter.seasonEpisode(season: 1, episode: 5) == "S1, E5")
    }

    /// Jellyfin returns a season without an episode number for specials and unnumbered entries,
    /// so a naive `"S\(s), " + "E\(e)"` would ship a dangling comma to a real screen.
    @Test("a season without an episode carries no trailing comma")
    func seasonOnly() {
        #expect(EpisodeMetadataFormatter.seasonEpisode(season: 1, episode: nil) == "S1")
    }

    @Test("an episode without a season is the bare episode token")
    func episodeOnly() {
        #expect(EpisodeMetadataFormatter.seasonEpisode(season: nil, episode: 5) == "E5")
    }

    @Test("neither number is the empty string, not nil")
    func neitherNumber() {
        #expect(EpisodeMetadataFormatter.seasonEpisode(season: nil, episode: nil) == "")
    }

    // MARK: - Label

    @Test("token and title join with the app's separator")
    func labelFull() {
        #expect(EpisodeMetadataFormatter.label(season: 1, episode: 5, title: "Pilot")
                == "S1, E5 · Pilot")
    }

    @Test("a missing title leaves no trailing separator")
    func labelWithoutTitle() {
        #expect(EpisodeMetadataFormatter.label(season: 1, episode: 5, title: nil) == "S1, E5")
        #expect(EpisodeMetadataFormatter.label(season: 1, episode: 5, title: "") == "S1, E5")
    }

    @Test("a missing token leaves the title alone")
    func labelWithoutNumbers() {
        #expect(EpisodeMetadataFormatter.label(season: nil, episode: nil, title: "Pilot") == "Pilot")
    }

    @Test("a season-implied surface renders the episode token alone")
    func labelEpisodeOnly() {
        #expect(EpisodeMetadataFormatter.label(season: nil, episode: 5, title: "Pilot")
                == "E5 · Pilot")
        #expect(EpisodeMetadataFormatter.label(season: nil, episode: 5, title: nil) == "E5")
    }

    @Test("nothing at all is the empty string")
    func labelEmpty() {
        #expect(EpisodeMetadataFormatter.label(season: nil, episode: nil, title: nil) == "")
    }

    // MARK: - Label with a series breadcrumb

    @Test("series, token and title are three segments")
    func labelWithSeries() {
        #expect(EpisodeMetadataFormatter.label(seriesName: "Friends", season: 3, episode: 15,
                                               title: "The One With The Lottery")
                == "Friends · S3, E15 · The One With The Lottery")
    }

    @Test("a series without numbers falls back to two segments")
    func labelSeriesAndTitle() {
        #expect(EpisodeMetadataFormatter.label(seriesName: "Friends", season: nil, episode: nil,
                                               title: "Pilot")
                == "Friends · Pilot")
    }

    @Test("a series without a title ends on the token")
    func labelSeriesAndNumbers() {
        #expect(EpisodeMetadataFormatter.label(seriesName: "Friends", season: 3, episode: 15,
                                               title: nil)
                == "Friends · S3, E15")
    }

    @Test("a series alone is the series")
    func labelSeriesOnly() {
        #expect(EpisodeMetadataFormatter.label(seriesName: "Friends", season: nil, episode: nil,
                                               title: nil)
                == "Friends")
    }

    @Test("a season without an episode keeps its breadcrumb comma-free")
    func labelSeriesSeasonOnly() {
        #expect(EpisodeMetadataFormatter.label(seriesName: "Friends", season: 1, episode: nil,
                                               title: nil)
                == "Friends · S1")
    }

    // MARK: - Live-TV cascade

    private func program(episodeTitle: String? = nil, seriesName: String? = nil,
                         season: Int? = nil, episode: Int? = nil) -> String? {
        EpisodeMetadataFormatter.programLabel(
            season: season, episode: episode,
            episodeTitle: episodeTitle, seriesName: seriesName, header: "Program Name")
    }

    @Test("an episode title follows the token")
    func programTitleWithNumbers() {
        #expect(program(episodeTitle: "Ross Finds Out", season: 2, episode: 21)
                == "S2, E21 · Ross Finds Out")
    }

    @Test("a series name precedes the token")
    func programSeriesWithNumbers() {
        #expect(program(seriesName: "Friends", season: 3, episode: 15) == "Friends · S3, E15")
    }

    @Test("an episode title outranks a series name")
    func programTitleBeatsSeries() {
        #expect(program(episodeTitle: "The Finale", seriesName: "The Show", season: 1, episode: 10)
                == "S1, E10 · The Finale")
    }

    @Test("numbers alone are a label")
    func programNumbersOnly() {
        #expect(program(season: 4, episode: 8) == "S4, E8")
    }

    /// The EPG token needs both halves: a lone "S4" beside a program name identifies nothing, and
    /// no guide surface supplies the missing half from context the way a series page does.
    @Test("a half-numbered program falls through to the next rung")
    func programHalfNumbers() {
        #expect(program(seriesName: "Friends", season: 3) == "Friends")
        #expect(program(season: 3) == nil)
        #expect(program(episode: 15) == nil)
    }

    @Test("a value equal to the header is dropped")
    func programHeaderDeduplication() {
        #expect(program(episodeTitle: "Program Name", seriesName: "The Show",
                        season: 2, episode: 5) == "The Show · S2, E5")
        #expect(program(episodeTitle: "Program Name", season: 1, episode: 2) == "S1, E2")
        #expect(program(seriesName: "Program Name", season: 1, episode: 1) == "S1, E1")
    }

    @Test("nothing left after the cascade is nil, not the empty string")
    func programNil() {
        #expect(program(episodeTitle: "Program Name") == nil)
        #expect(program() == nil)
    }
}
