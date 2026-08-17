import AetherEngine
import Foundation

/// Turns the engine's typed failure (`PlaybackErrorInfo`, AetherEngine#376) into the error screen's
/// icon + title + body trio.
///
/// Before this existed the host published `PlaybackState.error`'s text verbatim, which is the engine's own
/// English sentence about half the time ("Failed to load: HTTP 403 ..."). In a 26-language app that is an
/// untranslated string, and worse, it describes the plumbing rather than what the viewer can do: a refused
/// stream, a missing file and a metered origin all read the same. `kind` is the key that survives a locale
/// and a release (AetherEngine#378), so the host classifies on it and writes its own sentence.
///
/// Classification and copy are separate on purpose: `face(for:)` is testable without a locale, and only
/// `trio(for:engineMessage:)` reaches into the string catalog.
enum PlayerEngineErrorPresentation {

    /// Which of the host's error faces a typed failure maps to. Deliberately smaller than the engine's kind
    /// set: a face exists only where the host has a sentence that beats the engine's own.
    enum Face: Equatable {
        /// The origin answered the source request with a refusal (401 / 403).
        case streamRefused(status: Int)
        /// The origin says the file is not there any more (404 / 410).
        case streamNotFound
        /// The origin answered with a status instead of media, and it is the server's own fault (5xx).
        case streamServerError(status: Int)
        /// The origin is metering us (429 / 503 / 509). The source is not gone and the same request is
        /// expected to work later, so the copy asks for patience rather than reporting a failure.
        case rateLimited
        /// Dolby Vision with no base layer this device can decode.
        case dolbyVisionUnsupported
        /// A live probe that burned its reconnect budget without opening.
        case liveChannelUnavailable
        /// No host sentence beats the engine's: show what the engine said.
        case engineMessage
    }

    struct Trio: Equatable {
        let icon: String
        let title: String
        let message: String
    }

    /// `PlaybackErrorKind` is a string-backed struct so the engine can add kinds in a minor release
    /// without breaking a host that switches over it. Anything this build does not recognise therefore has
    /// to land on `.engineMessage`, never on a neighbouring face.
    static func face(for info: PlaybackErrorInfo?) -> Face {
        guard let info else { return .engineMessage }

        if info.kind == .sourceRefused {
            // The copy for a refusal names its status, so one that arrives without a status has nothing to
            // say that the engine's sentence does not say better.
            guard let status = info.underlyingCode else { return .engineMessage }
            switch status {
            case 401, 403: return .streamRefused(status: status)
            case 404, 410: return .streamNotFound
            default:       return .streamServerError(status: status)
            }
        }
        if info.kind == .sourceRateLimited { return .rateLimited }
        if info.kind == .dolbyVisionRequiresHardware { return .dolbyVisionUnsupported }
        if info.kind == .liveSourceUnavailable { return .liveChannelUnavailable }

        // `.nativeItemFailed` lands here on purpose: its message is AVFoundation's `localizedDescription`,
        // already in the device's language and more specific than anything the host could write.
        return .engineMessage
    }

    /// A live channel that never produced a frame reads as "unavailable", which is the honest verdict for a
    /// dead upstream and was the host's only live sentence before typed failures existed. Where the engine
    /// did type the failure, that naming is strictly better: a refused stream and a panel that is out of
    /// connection slots are both fixable, and neither is the channel being off the air.
    static func liveFace(for info: PlaybackErrorInfo?) -> Face {
        let face = face(for: info)
        return face == .engineMessage ? .liveChannelUnavailable : face
    }

    static func trio(for face: Face, engineMessage: String) -> Trio {
        switch face {
        case .streamRefused(let status):
            return Trio(
                icon: "lock.slash",
                title: String(
                    localized: "player.error.streamRefused.title",
                    defaultValue: "Stream refused"
                ),
                message: String(
                    format: String(
                        localized: "player.error.streamRefused.body",
                        defaultValue: "The server refused to deliver this stream (HTTP %lld). The item may not be shared with this account, or the session may have expired."
                    ),
                    status
                )
            )
        case .streamNotFound:
            return Trio(
                icon: "questionmark.folder",
                title: String(localized: "player.error.notFound.title", defaultValue: "Item unavailable"),
                message: String(
                    localized: "player.error.streamNotFound.body",
                    defaultValue: "The server no longer has this file. It may have been moved or removed from the library."
                )
            )
        case .streamServerError(let status):
            return Trio(
                icon: "server.rack",
                title: String(localized: "player.error.server.title", defaultValue: "Server error"),
                message: String(
                    format: String(
                        localized: "player.error.streamServerError.body",
                        defaultValue: "The server answered with HTTP %lld instead of the stream. Try again in a moment."
                    ),
                    status
                )
            )
        case .rateLimited:
            return Trio(
                icon: "antenna.radiowaves.left.and.right.slash",
                title: String(
                    localized: "player.error.rateLimited.title",
                    defaultValue: "Too many connections"
                ),
                message: String(
                    localized: "player.error.rateLimited.body",
                    defaultValue: "The source is not accepting another connection right now, usually because another device is already streaming from it. Wait a moment before trying again."
                )
            )
        case .dolbyVisionUnsupported:
            return Trio(
                icon: "questionmark.video",
                title: String(
                    localized: "player.error.dolbyVision.title",
                    defaultValue: "Dolby Vision not supported"
                ),
                message: String(
                    localized: "player.error.dolbyVision.body",
                    defaultValue: "This device cannot decode this Dolby Vision version. A different version of the file, or a device with Dolby Vision support, will play it."
                )
            )
        case .liveChannelUnavailable:
            return Trio(
                icon: "tv.slash",
                title: String(
                    localized: "player.error.liveUnavailable.title",
                    defaultValue: "Channel unavailable"
                ),
                message: String(
                    localized: "player.error.liveUnavailable.body",
                    defaultValue: "The server could not open this channel's stream. The channel's source may be offline. Try again later."
                )
            )
        case .engineMessage:
            return Trio(
                icon: "exclamationmark.triangle",
                title: String(localized: "player.error.playback.title", defaultValue: "Playback stopped"),
                message: engineMessage
            )
        }
    }

    /// One diagnostic line per typed failure. The raw sentence stops being visible to the viewer, so this is
    /// the only place it survives, and the kind / status is what a bug report needs anyway.
    static func logLine(for info: PlaybackErrorInfo?, engineMessage: String) -> String {
        guard let info else { return "[EngineError] kind=none message=\(engineMessage)" }
        let status = info.underlyingCode.map(String.init) ?? "-"
        let domain = info.underlyingDomain ?? "-"
        return "[EngineError] kind=\(info.kind.rawValue) code=\(status) domain=\(domain) message=\(info.message)"
    }
}
