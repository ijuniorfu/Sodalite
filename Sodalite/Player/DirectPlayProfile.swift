import Foundation
import AetherEngine

/// Jellyfin device profile for AetherEngine on Apple TV.
///
/// AetherEngine demuxes MKV/MP4/AVI/TS/VOB/3GP/M2TS natively via FFmpeg
/// and dispatches to either the native AVPlayer HLS path (HEVC, H.264,
/// AV1 with HW decode) or the SW pipeline (AV1 without HW, VP9, MPEG-4
/// Part 2, MPEG-2 video, VC-1). Server-side transcoding is reserved for
/// codecs outside this set (WMV3, Theora, RealVideo, etc.).
///
/// Two flavors based on display capabilities (see
/// `AetherEngine.displayCapabilities`):
///
/// - `permissiveHDRProfile`: HDR-capable display. Direct-play 4K HEVC
///   Main10 HDR10 / Dolby Vision / HLG with multichannel audio.
///
/// - `conservativeSDRProfile`: SDR display. HDR content is still
///   direct-played, VideoToolbox handles the conversion.
@MainActor
enum DirectPlayProfile {

    /// Picks the right profile based on the runtime display capabilities.
    static func current() -> [String: Any] {
        let caps = AetherEngine.displayCapabilities
        let useHDR = caps.supportsHDR
        #if DEBUG
        print("[Profile] Display: HDR=\(caps.supportsHDR) DV=\(caps.supportsDolbyVision) HDR10=\(caps.supportsHDR10) HLG=\(caps.supportsHLG) → using \(useHDR ? "HDR" : "SDR") profile")
        #endif
        return useHDR ? permissiveHDRProfile() : conservativeSDRProfile()
    }

    /// Profile for live TV channels. A live channel is an unbounded stream,
    /// so the VOD fallback of a progressive MP4 transcode does not work: an
    /// MP4 only finalizes its `moov` atom at EOF, which never comes for live,
    /// so the server returns a broken URL it then rejects with HTTP 400.
    /// MPEG-TS over progressive HTTP IS live-streamable, and it is exactly
    /// what AetherEngine's live path consumes (raw MPEG-TS over HTTP via its
    /// AVIO reader). So we keep the direct-play set but force a TS transcode.
    static func liveProfile() -> [String: Any] {
        var profile = current()
        profile["TranscodingProfiles"] = [
            [
                "Type": "Video",
                "Container": "ts",
                "Protocol": "http",
                "VideoCodec": "h264,hevc",
                "AudioCodec": "aac,ac3,eac3,mp3",
                "Context": "Streaming",
            ],
        ] as [[String: Any]]
        return profile
    }

    // MARK: - HDR-capable display

    /// Profile for HDR-capable Apple TV setups (HDR display + Match
    /// Dynamic Range on). AetherEngine handles HEVC Main10, HDR10,
    /// Dolby Vision (Profile 5/8.1/8.4), HLG, and multichannel audio.
    /// Server only has to remux containers, no re-encoding.
    static func permissiveHDRProfile() -> [String: Any] {
        [
            "MaxStreamingBitrate": 200_000_000,
            "MaxStaticBitrate": 200_000_000,
            "MusicStreamingTranscodingBitrate": 384_000,

            // AetherEngine (FFmpeg) handles these containers natively.
            // Video codecs match the engine's dispatch table in
            // `AetherEngine.swift`: HEVC / H.264 / AV1 (HW) go to the
            // native AVPlayer HLS path; AV1 (no HW), VP9, MPEG-4 Part 2,
            // MPEG-2 video, and VC-1 take the SW pipeline. Listing them
            // here stops Jellyfin from server-transcoding XVID / DivX,
            // MPEG-2 broadcast remuxes, and VC-1 BD rips.
            "DirectPlayProfiles": [
                [
                    "Container": "mp4,m4v,mov,mkv,matroska,avi,mpegts,ts,m2ts,mts,3gp,3g2,vob,ogg,webm,flv",
                    "Type": "Video",
                    "VideoCodec": "h264,hevc,av1,vp9,vp8,mpeg4,mpeg2video,vc1",
                    // Jellyfin reports DTS variants inconsistently, some
                    // builds use `dts`, some `dca`, some `dts-hd`. Listing
                    // every spelling we've seen stops the server from
                    // kicking DTS-HD MA into a transcode just because our
                    // profile didn't happen to use the exact string it
                    // chose this release. mp2 pairs with MPEG-2 video
                    // (broadcast / VOB sources).
                    "AudioCodec": "aac,ac3,eac3,mp3,mp2,flac,opus,vorbis,alac,truehd,mlp,dts,dca,dts-hd,dtshd,pcm_s16le,pcm_s24le,pcm_f32le",
                ],
                [
                    "Container": "mp3,aac,m4a,m4b,flac,alac,wav,opus,ogg",
                    "Type": "Audio",
                ],
            ] as [[String: Any]],

            // Fallback: progressive MP4 over HTTP (not HLS!). AetherEngine
            // uses a custom AVIO context with URLSession for HTTP streams,
            // which doesn't support HLS playlists. HTTP progressive download
            // works perfectly with our read-ahead buffer.
            "TranscodingProfiles": [
                [
                    "Type": "Video",
                    "Container": "mp4",
                    "Protocol": "http",
                    "VideoCodec": "h264,hevc,av1,vp9",
                    "AudioCodec": "aac,ac3,eac3",
                    "Context": "Streaming",
                ],
                [
                    "Type": "Audio",
                    "Container": "mp3",
                    "Protocol": "http",
                    "AudioCodec": "mp3",
                    "Context": "Streaming",
                ],
            ] as [[String: Any]],

            "ContainerProfiles": [] as [Any],
            "CodecProfiles": [] as [[String: Any]],
            "SubtitleProfiles": Self.subtitleProfiles,
        ]
    }

    // MARK: - SDR display fallback

    /// Profile for SDR displays (or HDR displays with Match Dynamic
    /// Range off).
    ///
    /// Strategy: maximise direct play and container-remux (DirectStream),
    /// keep TranscodingProfile permissive so the server can stream-copy
    /// compatible codecs instead of re-encoding them. Server-side
    /// transcoding is the absolute last resort.
    ///
    /// HDR sources are intentionally NOT constrained here, VideoToolbox
    /// handles HDR-on-SDR conversion automatically.
    static func conservativeSDRProfile() -> [String: Any] {
        [
            "MaxStreamingBitrate": 200_000_000,
            "MaxStaticBitrate": 200_000_000,
            "MusicStreamingTranscodingBitrate": 384_000,

            // AetherEngine (FFmpeg) handles these containers natively.
            // Video codecs match the engine's dispatch table; see HDR
            // profile comment for the SW vs native split.
            "DirectPlayProfiles": [
                [
                    "Container": "mp4,m4v,mov,mkv,matroska,avi,mpegts,ts,m2ts,mts,3gp,3g2,vob,ogg,webm,flv",
                    "Type": "Video",
                    "VideoCodec": "h264,hevc,av1,vp9,vp8,mpeg4,mpeg2video,vc1",
                    // Jellyfin reports DTS variants inconsistently, some
                    // builds use `dts`, some `dca`, some `dts-hd`. Listing
                    // every spelling we've seen stops the server from
                    // kicking DTS-HD MA into a transcode just because our
                    // profile didn't happen to use the exact string it
                    // chose this release. mp2 pairs with MPEG-2 video
                    // (broadcast / VOB sources).
                    "AudioCodec": "aac,ac3,eac3,mp3,mp2,flac,opus,vorbis,alac,truehd,mlp,dts,dca,dts-hd,dtshd,pcm_s16le,pcm_s24le,pcm_f32le",
                ],
                [
                    "Container": "mp3,aac,m4a,m4b,flac,alac,wav,opus,ogg",
                    "Type": "Audio",
                ],
            ] as [[String: Any]],

            // Fallback: progressive MP4 over HTTP (not HLS!).
            "TranscodingProfiles": [
                [
                    "Type": "Video",
                    "Container": "mp4",
                    "Protocol": "http",
                    "VideoCodec": "h264,hevc,av1,vp9",
                    "AudioCodec": "aac,ac3,eac3",
                    "Context": "Streaming",
                ],
                [
                    "Type": "Audio",
                    "Container": "mp3",
                    "Protocol": "http",
                    "AudioCodec": "mp3",
                    "Context": "Streaming",
                ],
            ] as [[String: Any]],

            "ContainerProfiles": [] as [Any],
            "CodecProfiles": [] as [[String: Any]],
            "SubtitleProfiles": Self.subtitleProfiles,
        ]
    }

    // MARK: - Subtitles (shared)

    /// All subtitle formats delivered externally, we fetch them as SRT
    /// via the Jellyfin subtitle API (server converts any format to SRT).
    /// This prevents Jellyfin from transcoding the entire video stream
    /// just because a subtitle codec is "unsupported".
    private static let subtitleProfiles: [[String: Any]] = [
        ["Format": "vtt", "Method": "External"],
        ["Format": "webvtt", "Method": "External"],
        ["Format": "srt", "Method": "External"],
        ["Format": "subrip", "Method": "External"],
        ["Format": "ass", "Method": "External"],
        ["Format": "ssa", "Method": "External"],
        ["Format": "pgssub", "Method": "External"],
        ["Format": "pgs", "Method": "External"],
        ["Format": "dvdsub", "Method": "External"],
        ["Format": "dvbsub", "Method": "External"],
    ]
}
