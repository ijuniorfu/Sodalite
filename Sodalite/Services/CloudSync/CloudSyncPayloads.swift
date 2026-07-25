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
    case trackMemory
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
    /// CollectionGrouping raw value (Sodalite#44). Optional: payloads written before the field
    /// existed must still decode, and a missing value must not reset a device's local mode.
    var collectionGrouping: String?
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
    /// The three below are optional because they were added after the payload shipped.
    /// Swift's synthesized Decodable does NOT fall back to a property default on a missing
    /// key, it throws, and one thrown key drops the whole payload: a device on an older
    /// build would silently stop syncing its playback settings to a newer one. A missing
    /// value means keep-current on apply, never reset.
    var playerRotationLocked: Bool?
    var networkBufferDepth: String?
    var rememberTrackSelections: Bool?
}

/// Sodalite#46. Unlike the other settings payloads this one is NOT last-writer-wins:
/// each entry carries its own stamp and `CloudSyncMerge.unionTrackMemory` merges per key,
/// else a title watched on the Apple TV would erase one watched on the iPhone.
struct TrackMemoryPayload: Codable, Equatable {
    var schemaVersion: Int = 1
    var updatedAt: Date
    var entries: [String: TrackMemoryEntry]
}

struct AppearanceSettingsPayload: Codable, Equatable {
    var schemaVersion: Int
    var updatedAt: Date
    var accentChoice: String
    var backgroundStyle: String
    var showContentLogos: Bool
    var continueWatchingImage: String
    var largeCards: Bool
    var nowPlayingUsesSeriesPoster: Bool

    init(
        schemaVersion: Int = 2,
        updatedAt: Date,
        accentChoice: String,
        backgroundStyle: String,
        showContentLogos: Bool,
        continueWatchingImage: String,
        largeCards: Bool,
        nowPlayingUsesSeriesPoster: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.accentChoice = accentChoice
        self.backgroundStyle = backgroundStyle
        self.showContentLogos = showContentLogos
        self.continueWatchingImage = continueWatchingImage
        self.largeCards = largeCards
        self.nowPlayingUsesSeriesPoster = nowPlayingUsesSeriesPoster
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case updatedAt
        case accentChoice
        case backgroundStyle
        case showContentLogos
        case continueWatchingImage
        case largeCards
        case nowPlayingUsesSeriesPoster
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        accentChoice = try values.decode(String.self, forKey: .accentChoice)
        backgroundStyle = try values.decodeIfPresent(String.self, forKey: .backgroundStyle)
            ?? BackgroundStyle.graphiteGlass.rawValue
        showContentLogos = try values.decode(Bool.self, forKey: .showContentLogos)
        continueWatchingImage = try values.decode(String.self, forKey: .continueWatchingImage)
        largeCards = try values.decode(Bool.self, forKey: .largeCards)
        nowPlayingUsesSeriesPoster = try values.decode(
            Bool.self,
            forKey: .nowPlayingUsesSeriesPoster
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(2, forKey: .schemaVersion)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(accentChoice, forKey: .accentChoice)
        try values.encode(backgroundStyle, forKey: .backgroundStyle)
        try values.encode(showContentLogos, forKey: .showContentLogos)
        try values.encode(continueWatchingImage, forKey: .continueWatchingImage)
        try values.encode(largeCards, forKey: .largeCards)
        try values.encode(nowPlayingUsesSeriesPoster, forKey: .nowPlayingUsesSeriesPoster)
    }
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
    case trackMemory(TrackMemoryPayload)

    var storeKey: CloudSyncStoreKey {
        switch self {
        case .playback: .playback
        case .appearance: .appearance
        case .auth: .auth
        case .seerrNotifications: .seerrNotifications
        case .parentalControls: .parentalControls
        case .trackMemory: .trackMemory
        }
    }

    var updatedAt: Date {
        switch self {
        case .playback(let p): p.updatedAt
        case .appearance(let p): p.updatedAt
        case .auth(let p): p.updatedAt
        case .seerrNotifications(let p): p.updatedAt
        case .parentalControls(let p): p.updatedAt
        case .trackMemory(let t): t.updatedAt
        }
    }

    func restamped(_ stamp: Date) -> SettingsSyncPayload {
        switch self {
        case .playback(var p): p.updatedAt = stamp; return .playback(p)
        case .appearance(var p): p.updatedAt = stamp; return .appearance(p)
        case .auth(var p): p.updatedAt = stamp; return .auth(p)
        case .seerrNotifications(var p): p.updatedAt = stamp; return .seerrNotifications(p)
        case .parentalControls(var p): p.updatedAt = stamp; return .parentalControls(p)
        case .trackMemory(var t): t.updatedAt = stamp; return .trackMemory(t)
        }
    }

    func encoded() throws -> Data {
        switch self {
        case .playback(let p): try JSONEncoder().encode(p)
        case .appearance(let p): try JSONEncoder().encode(p)
        case .auth(let p): try JSONEncoder().encode(p)
        case .seerrNotifications(let p): try JSONEncoder().encode(p)
        case .parentalControls(let p): try JSONEncoder().encode(p)
        case .trackMemory(let t): try JSONEncoder().encode(t)
        }
    }

    static func decode(_ data: Data, key: CloudSyncStoreKey) throws -> SettingsSyncPayload {
        switch key {
        case .playback: .playback(try JSONDecoder().decode(PlaybackSettingsPayload.self, from: data))
        case .appearance: .appearance(try JSONDecoder().decode(AppearanceSettingsPayload.self, from: data))
        case .auth: .auth(try JSONDecoder().decode(AuthSettingsPayload.self, from: data))
        case .seerrNotifications: .seerrNotifications(try JSONDecoder().decode(SeerrNotificationSettingsPayload.self, from: data))
        case .parentalControls: .parentalControls(try JSONDecoder().decode(ParentalControlsSettingsPayload.self, from: data))
        case .trackMemory: .trackMemory(try JSONDecoder().decode(TrackMemoryPayload.self, from: data))
        }
    }
}
