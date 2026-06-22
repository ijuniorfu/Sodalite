import Foundation

/// One entry from `/api/v1/discover/genreslider/movie` (or `/tv`); curated discover-page genres with backdrops for imagery cards.
struct SeerrGenreSlide: Codable, Sendable, Identifiable, Equatable, Hashable {
    let id: Int
    let name: String
    let backdrops: [String]?

    /// First backdrop for the tile hero; nil callers fall back to a solid-tint card.
    var primaryBackdrop: String? { backdrops?.first }
}
