import Foundation
import Testing
@testable import Sodalite

struct SeerrImageURLTests {
    /// TMDB has no profile rendition between w185 and h632, so the picker has exactly one step.
    @Test func profileSizeCoversRequestedPixels() {
        #expect(SeerrImageURL.ProfileSize.covering(185) == .w185)
        #expect(SeerrImageURL.ProfileSize.covering(186) == .h632)
        #expect(SeerrImageURL.ProfileSize.covering(LayoutMetrics.tv.castImageWidth) == .h632)
        #expect(SeerrImageURL.ProfileSize.covering(LayoutMetrics.compact.castImageWidth) == .h632)
    }

    @Test func profileURLUsesChosenRendition() {
        let url = SeerrImageURL.profile(path: "/abc.jpg", size: .h632)
        #expect(url?.absoluteString == "https://image.tmdb.org/t/p/h632/abc.jpg")
    }

    @Test func profileURLIsNilWithoutPath() {
        #expect(SeerrImageURL.profile(path: nil) == nil)
        #expect(SeerrImageURL.profile(path: "") == nil)
    }
}
