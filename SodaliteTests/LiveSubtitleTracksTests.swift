import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// Live TV has no Jellyfin stream list, so the engine's own track table is the source. The index
/// must survive the mapping unchanged: it is the AVStream index the engine expects back on select.
struct LiveSubtitleTracksTests {

    private func track(id: Int, name: String = "", codec: String = "dvb_teletext",
                       language: String? = "deu", forced: Bool = false,
                       external: Bool = false) -> TrackInfo {
        TrackInfo(id: id, name: name, codec: codec, language: language,
                  isDefault: false, isForced: forced, isExternal: external)
    }

    @Test("the engine's stream index survives the mapping")
    func indexIsCarried() {
        let mapped = LiveSubtitleTracks.mediaStreams(from: [track(id: 7)])
        #expect(mapped.map(\.index) == [7])
    }

    @Test("language, codec and the forced flag are carried")
    func metadataIsCarried() {
        let mapped = LiveSubtitleTracks.mediaStreams(from: [
            track(id: 3, name: "Untertitel", codec: "dvb_subtitle", language: "deu", forced: true)
        ])
        #expect(mapped.first?.language == "deu")
        #expect(mapped.first?.codec == "dvb_subtitle")
        #expect(mapped.first?.isForced == true)
        #expect(mapped.first?.title == "Untertitel")
        #expect(mapped.first?.type == .subtitle)
        #expect(mapped.first?.isExternal == false)
    }

    @Test("a nameless broadcast track gets no invented title")
    func namelessTrackKeepsNoTitle() {
        #expect(LiveSubtitleTracks.mediaStreams(from: [track(id: 1)]).first?.title == nil)
    }

    /// External tracks carry a synthetic id, not an AVStream index, and reach the engine through a
    /// different select path. They cannot occur on live, and mapping one would hand out an index
    /// that resolves to nothing.
    @Test("host-registered external tracks are not mapped")
    func externalTracksAreDropped() {
        #expect(LiveSubtitleTracks.mediaStreams(from: [track(id: 900_001, external: true)]).isEmpty)
    }

    @Test("an empty engine list maps to an empty stream list")
    func emptyStaysEmpty() {
        #expect(LiveSubtitleTracks.mediaStreams(from: []).isEmpty)
    }
}
