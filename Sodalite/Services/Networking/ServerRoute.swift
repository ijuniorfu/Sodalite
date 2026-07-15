import Foundation

/// Which URL slot a session is currently pinned to. Raw values are persisted
/// (UserDefaults last-known route) and must stay stable.
enum ServerRoute: String, Codable, Sendable {
    case `internal`
    case external
}
