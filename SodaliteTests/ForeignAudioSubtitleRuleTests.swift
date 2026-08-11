import Testing
import Foundation
@testable import Sodalite

/// The automatic-subtitle rule ("your audio is not in your language, so here are subtitles") must
/// treat an untagged audio track as unknown, not as foreign. Live HLS audio renditions carry no
/// language at all, so the old reading switched subtitles on for every channel a viewer opened.
@MainActor
struct ForeignAudioSubtitleRuleTests {

    @Test("a different language counts as foreign")
    func differentLanguageIsForeign() {
        #expect(PlayerViewModel.audioCountsAsForeign(audioLanguage: "jpn", preferredAudio: "de"))
    }

    @Test("the same language in another code form does not")
    func sameLanguageIsNotForeign() {
        #expect(!PlayerViewModel.audioCountsAsForeign(audioLanguage: "deu", preferredAudio: "de"))
        #expect(!PlayerViewModel.audioCountsAsForeign(audioLanguage: "ger", preferredAudio: "de"))
    }

    @Test("an untagged track is unknown, not foreign")
    func untaggedAudioIsNotForeign() {
        #expect(!PlayerViewModel.audioCountsAsForeign(audioLanguage: nil, preferredAudio: "de"))
        #expect(!PlayerViewModel.audioCountsAsForeign(audioLanguage: "", preferredAudio: "de"))
        #expect(!PlayerViewModel.audioCountsAsForeign(audioLanguage: "und", preferredAudio: "de"))
    }

    @Test("without a preferred language nothing is foreign")
    func noPreferenceMeansNoRule() {
        #expect(!PlayerViewModel.audioCountsAsForeign(audioLanguage: "jpn", preferredAudio: nil))
    }
}
