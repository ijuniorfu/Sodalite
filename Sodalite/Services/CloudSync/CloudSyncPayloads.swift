import Foundation

/// Wire types for CloudKit sync. Payloads travel as one JSON blob per record in
/// CKRecord.encryptedValues["payload"]; `updatedAt` drives last-writer-wins.
/// Enums travel as raw strings and map with keep-current fallback on apply, so
/// an older build never fails a whole payload on an unknown case.
enum CloudSyncRecordType {
    static let server = "SyncServer"
    static let settings = "SyncSettingsStore"
    static let security = "SyncSecurity"
}

enum CloudSyncStoreKey: String, CaseIterable, Codable {
    case playback
    case appearance
    case auth
    case seerrNotifications
    case parentalControls
}

enum CloudSyncRecordName {
    static let securitySingleton = "security"

    static func server(id: String) -> String { "server-\(id)" }
    static func settings(_ key: CloudSyncStoreKey) -> String { "settings-\(key.rawValue)" }

    static func serverID(fromRecordName name: String) -> String? {
        guard name.hasPrefix("server-") else { return nil }
        return String(name.dropFirst("server-".count))
    }

    static func storeKey(fromRecordName name: String) -> CloudSyncStoreKey? {
        guard name.hasPrefix("settings-") else { return nil }
        return CloudSyncStoreKey(rawValue: String(name.dropFirst("settings-".count)))
    }
}

/// Per-server home row customization. configsJSON stays opaque raw JSON of
/// [HomeRowConfig] to preserve HomeRowConfig.loadFromStorage's lossy-decode
/// forward compatibility across app versions.
struct HomeRowsSyncState: Codable, Equatable {
    var configsJSON: Data?
    var mergeCWNextUp: Bool
    var rewatchNextUp: Bool
}

struct ServerSyncPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var server: JellyfinServer
    var rememberedUsers: [RememberedUser]
    var jellyfinPassword: String?
    /// The user the stored password belongs to; the silent re-login fallback
    /// only fires when this matches the profile being restored.
    var passwordUserID: String?
    var seerrSessions: [RememberedSeerrSession]
    var homeRows: HomeRowsSyncState?
}

struct PlaybackSettingsPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var autoplayNextEpisode: Bool
    var autoSkipIntro: Bool
    var autoSkipOutro: Bool
    var nextEpisodeCountdownSeconds: Int
    var skipIntervalSeconds: Int
    var preferredAudioLanguage: String?
    var preferredSubtitleLanguage: String?
    var autoSubtitleForForeignAudio: Bool
    var styledASSSubtitles: Bool
    var subtitleFontSize: String
    var subtitleColor: String
    var subtitleBackground: String
    var subtitleDelaySeconds: Double
    var subtitleVerticalPosition: String
    var subtitleFont: String
    var subtitleWeight: String
    var pictureMode: String
    var showStatsForNerds: Bool
    var showEngineDiagnostics: Bool
    var showDiagnosticOverlay: Bool
    var focusDiagnosticOverlayOnDV: Bool
    var preferLosslessAudioBridge: Bool
    var showScrubPreview: Bool
    var preferServerTrickplay: Bool
    var playerRotationLocked: Bool
    var networkBufferDepth: String
}

struct AppearanceSettingsPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var accentChoice: String
    var showContentLogos: Bool
    var continueWatchingImage: String
    var largeCards: Bool
    var nowPlayingUsesSeriesPoster: Bool
}

struct AuthSettingsPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var launchBehavior: String
    var defaultUserID: String?
    var defaultServerID: String?
}

struct SeerrNotificationSettingsPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var notifyPendingRequests: Bool
}

struct ParentalControlsSettingsPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var protectedProfileIDs: [String]
}

struct SecuritySyncPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var pinBlob: GuardianPINCrypto.Blob
}

/// Type-erased settings payload so the engine can treat all five stores uniformly.
enum SettingsSyncPayload: Equatable {
    case playback(PlaybackSettingsPayload)
    case appearance(AppearanceSettingsPayload)
    case auth(AuthSettingsPayload)
    case seerrNotifications(SeerrNotificationSettingsPayload)
    case parentalControls(ParentalControlsSettingsPayload)

    var storeKey: CloudSyncStoreKey {
        switch self {
        case .playback: .playback
        case .appearance: .appearance
        case .auth: .auth
        case .seerrNotifications: .seerrNotifications
        case .parentalControls: .parentalControls
        }
    }

    var updatedAt: Date {
        switch self {
        case .playback(let p): p.updatedAt
        case .appearance(let p): p.updatedAt
        case .auth(let p): p.updatedAt
        case .seerrNotifications(let p): p.updatedAt
        case .parentalControls(let p): p.updatedAt
        }
    }

    func restamped(_ stamp: Date) -> SettingsSyncPayload {
        switch self {
        case .playback(var p): p.updatedAt = stamp; return .playback(p)
        case .appearance(var p): p.updatedAt = stamp; return .appearance(p)
        case .auth(var p): p.updatedAt = stamp; return .auth(p)
        case .seerrNotifications(var p): p.updatedAt = stamp; return .seerrNotifications(p)
        case .parentalControls(var p): p.updatedAt = stamp; return .parentalControls(p)
        }
    }

    func encoded() throws -> Data {
        switch self {
        case .playback(let p): try JSONEncoder().encode(p)
        case .appearance(let p): try JSONEncoder().encode(p)
        case .auth(let p): try JSONEncoder().encode(p)
        case .seerrNotifications(let p): try JSONEncoder().encode(p)
        case .parentalControls(let p): try JSONEncoder().encode(p)
        }
    }

    static func decode(_ data: Data, key: CloudSyncStoreKey) throws -> SettingsSyncPayload {
        switch key {
        case .playback: .playback(try JSONDecoder().decode(PlaybackSettingsPayload.self, from: data))
        case .appearance: .appearance(try JSONDecoder().decode(AppearanceSettingsPayload.self, from: data))
        case .auth: .auth(try JSONDecoder().decode(AuthSettingsPayload.self, from: data))
        case .seerrNotifications: .seerrNotifications(try JSONDecoder().decode(SeerrNotificationSettingsPayload.self, from: data))
        case .parentalControls: .parentalControls(try JSONDecoder().decode(ParentalControlsSettingsPayload.self, from: data))
        }
    }
}
