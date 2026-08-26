import Testing
import Foundation
@testable import Sodalite

/// Collections and Playlists were opt-in rows nobody found: a reporter took the missing shelves for
/// a missing feature (mikepaggi, Sodalite#73). Both are on by default now, which is safe because a
/// server without either renders nothing (HomeViewModel drops empty rows before display).
///
/// Playlists carries one condition: Jellyfin fixes a playlist's media type at creation and returns
/// audio and video playlists from the same query, while the playlist screen lists video leaves only.
/// An audio playlist on a video shelf therefore opens a page with no list and two buttons that
/// enqueue nothing, so the row has to drop them before the default can be turned on.
struct CollectionPlaylistHomeRowTests {

    private func item(type: String, mediaType: String?) -> JellyfinItem {
        let media = mediaType.map { ",\"MediaType\":\"\($0)\"" } ?? ""
        let json = "{\"Id\":\"p1\",\"Name\":\"Item\",\"Type\":\"\(type)\"\(media)}"
        return try! JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }

    @Test func bothRowsAreEnabledByDefault() {
        #expect(HomeRowType.collections.defaultEnabled)
        #expect(HomeRowType.playlists.defaultEnabled)
        let defaults = HomeRowConfig.defaultConfig()
        #expect(defaults.first { $0.type == .collections }?.isEnabled == true)
        #expect(defaults.first { $0.type == .playlists }?.isEnabled == true)
    }

    /// A saved layout wins over a changed default: reconciliation only appends types it has never
    /// seen, so nobody's home screen grows a row behind their back on update.
    @Test func changedDefaultDoesNotOverrideASavedLayout() {
        var stored = HomeRowConfig.defaultConfig()
        for type in [HomeRowType.collections, .playlists] {
            if let idx = stored.firstIndex(where: { $0.type == type }) {
                stored[idx].isEnabled = false
            }
        }

        let after = HomeRowConfig.reconciled(stored: stored, libraries: [])

        #expect(after.first { $0.type == .collections }?.isEnabled == false)
        #expect(after.first { $0.type == .playlists }?.isEnabled == false)
    }

    @Test func audioPlaylistIsRecognised() {
        #expect(item(type: "Playlist", mediaType: "Audio").isAudioPlaylist)
        // Jellyfin's own casing is "Audio"; a server that spells it differently must not slip through.
        #expect(item(type: "Playlist", mediaType: "audio").isAudioPlaylist)
        #expect(!item(type: "Playlist", mediaType: "Video").isAudioPlaylist)
        // Unknown or absent stays visible: dropping it would hide video playlists on any server
        // that does not report the field.
        #expect(!item(type: "Playlist", mediaType: nil).isAudioPlaylist)
    }

    /// The flag is about playlists, not about audio: a music track carries MediaType "Audio" too,
    /// and the rows that legitimately show tracks must not lose them.
    @Test func audioTrackIsNotAnAudioPlaylist() {
        let track = item(type: "Audio", mediaType: "Audio")
        #expect(!track.isAudioPlaylist)
    }

    /// MediaType rides along on a plain /Items response, no `Fields=` entry to forget.
    @Test func mediaTypeDecodesFromTheItemPayload() {
        #expect(item(type: "Playlist", mediaType: "Video").mediaType == "Video")
        #expect(item(type: "Playlist", mediaType: nil).mediaType == nil)
    }
}
