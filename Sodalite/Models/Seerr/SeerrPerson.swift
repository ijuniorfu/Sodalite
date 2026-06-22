import Foundation

/// `/api/v1/person/{id}`. Bare camelCase only: client uses `.convertFromSnakeCase`, so do NOT add snake_case CodingKeys (breaks decoding under that strategy).
struct SeerrPersonDetail: Codable, Sendable, Equatable {
    let id: Int
    let name: String
    let biography: String?
    let profilePath: String?
    let knownForDepartment: String?
    let birthday: String?
    let deathday: String?
    let placeOfBirth: String?
}

/// `/api/v1/person/{id}/combined_credits`. Entries are a superset of `SeerrMedia` (extra character/job ignored), decoded as `SeerrMedia` to reuse the catalog card.
struct SeerrPersonCredits: Codable, Sendable, Equatable {
    let cast: [SeerrMedia]?
    let crew: [SeerrMedia]?
}
