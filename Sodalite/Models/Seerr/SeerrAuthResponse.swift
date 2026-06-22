import Foundation

/// Body for `POST /api/v1/auth/jellyfin`: credentials only, no `hostname` (re-sending it on a configured server returns HTTP 500 "jellyfin hostname already configured").
struct SeerrJellyfinAuthBody: Encodable, Sendable {
    let username: String
    let password: String
}
