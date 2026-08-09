import Foundation
import Testing
@testable import Sodalite

@Suite("Media segment request")
struct MediaSegmentRequestTests {
    @Test("the segments endpoint asks for intro, outro and recap")
    func requestsAllThreeSegmentTypes() {
        let items = JellyfinEndpoint.mediaSegments(itemID: "abc").queryItems ?? []
        let types = items.filter { $0.name == "includeSegmentTypes" }.compactMap(\.value)
        #expect(Set(types) == ["Intro", "Outro", "Recap"])
    }

    @Test("a recap marker decodes into the paired result")
    func recapDecodes() throws {
        let json = """
        {"Items":[
          {"Id":"1","ItemId":"abc","Type":"Recap","StartTicks":0,"EndTicks":300000000},
          {"Id":"2","ItemId":"abc","Type":"Intro","StartTicks":300000000,"EndTicks":900000000}
        ],"TotalRecordCount":2}
        """
        let response = try JSONDecoder().decode(MediaSegmentsResponse.self, from: Data(json.utf8))
        let segments = EpisodeSegments(
            intro: response.items.first(where: { $0.type == .intro }),
            outro: response.items.first(where: { $0.type == .outro }),
            recap: response.items.first(where: { $0.type == .recap })
        )
        #expect(segments.recap?.endSeconds == 30)
        #expect(segments.intro?.startSeconds == 30)
        #expect(segments.outro == nil)
    }
}
