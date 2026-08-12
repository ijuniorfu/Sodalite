import Foundation
import Testing
import AetherEngine
@testable import Sodalite

/// The transport-bar chip label. A live channel is the case that pushed on this: broadcasters
/// routinely leave the audio stream untagged, and the container's own name for such a track reads
/// "Track 0 (aac)", which says nothing a viewer wants on a chip.
@Suite("Track chip label")
struct TrackDisplayFormatterTests {
    private func audio(language: String?, codec: String = "aac", channels: Int = 2,
                       name: String = "Track 0 (aac)", isAtmos: Bool = false) -> TrackInfo {
        TrackInfo(id: 0, name: name, codec: codec, language: language,
                  channels: channels, isDefault: true, isAtmos: isAtmos)
    }

    @Test("a tagged track shows its language, which is what the viewer picks by")
    func languageWins() {
        // Derived, not spelled: the label is the viewer's language name for the code, so a literal
        // here would only assert the locale the test happened to run in.
        let expected = Locale.current.localizedString(forLanguageCode: "de").map {
            $0.prefix(1).uppercased() + $0.dropFirst()
        }
        #expect(TrackDisplayFormatter.shortName(for: audio(language: "de")) == expected)
    }

    @Test("an untagged track falls back to the format, not to the container's track name")
    func untaggedFallsBackToFormat() {
        let label = TrackDisplayFormatter.shortName(for: audio(language: nil))
        #expect(label != "Track 0 (aac)")
        #expect(label.contains("AAC"))
    }

    @Test("an empty language string counts as untagged")
    func emptyLanguageIsUntagged() {
        #expect(TrackDisplayFormatter.shortName(for: audio(language: "")).contains("AAC"))
    }

    @Test("Atmos names itself rather than its bed layout")
    func atmosOverridesLayout() {
        let track = audio(language: nil, codec: "eac3", channels: 6, isAtmos: true)
        #expect(TrackDisplayFormatter.shortName(for: track) == "Dolby Atmos")
    }

    @Test("a track with neither language nor a describable format keeps its name")
    func lastResortIsTheName() {
        let track = audio(language: nil, codec: "", channels: 0, name: "Commentary")
        #expect(TrackDisplayFormatter.shortName(for: track) == "Commentary")
    }
}
