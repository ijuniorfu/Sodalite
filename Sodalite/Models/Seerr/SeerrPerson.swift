import Foundation

/// `/api/v1/person/{id}`. Bare camelCase only — the Seerr client uses
/// `.convertFromSnakeCase`, so `profile_path` -> `profilePath`,
/// `known_for_department` -> `knownForDepartment`, etc. Do NOT add
/// snake_case CodingKeys (that breaks decoding under that strategy).
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

/// `/api/v1/person/{id}/combined_credits`. Each credit entry is a
/// superset of `SeerrMedia` (it also carries `character`/`job`, which
/// the `SeerrMedia` decoder ignores), so we decode entries as
/// `SeerrMedia` directly and reuse the catalog card.
struct SeerrPersonCredits: Codable, Sendable, Equatable {
    let cast: [SeerrMedia]?
    let crew: [SeerrMedia]?
}
