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

    /// Live channel "copy ceiling": the bitrate at/under which a compatible
    /// codec is stream-copied rather than re-encoded. Kept as high as the VOD
    /// direct-play ceiling so any broadcast H.264/HEVC (1080p ~20 Mbps, 4K
    /// ~50 Mbps) stays under it and Jellyfin copies the bitstream instead of
    /// re-encoding. CAVEAT: this is also the encoder target for the rare
    /// channel whose source codec is genuinely incompatible (e.g. MPEG-2 OTA),
    /// where a real-time re-encode to this ceiling would stall. Those need a
    /// separate per-codec re-encode cap if/when they show up; this environment
    /// is H.264 IPTV, which copies.
    static let liveCopyCeilingBitrate = 200_000_000

    /// Bitrate target for live channels the server genuinely has to RE-ENCODE
    /// (the probe reports `VideoCodecNotSupported`, e.g. an MPEG-2 / MPEG-4
    /// OTA source). For those the request bitrate IS the encoder target, so it
    /// must be a value a server can sustain as a real-time encode, not the
    /// copy ceiling (which produced a 199 Mbps target the server answered with
    /// HTTP 500). 12 Mbps is a sane real-time H.264 target. Only applied on the
    /// re-encode fallback path; compatible codecs keep the copy ceiling and are
    /// stream-copied.
    static let liveReencodeCapBitrate = 12_000_000

    /// Profile for live TV channels. Two things differ from VOD:
    ///
    /// 1. **Protocol=hls.** We request an HLS sub-protocol so Jellyfin returns
    ///    a `master.m3u8` (TS segments under an HLS wrapper) that AVPlayer
    ///    plays NATIVELY. Live then bypasses AetherEngine's demux/remux/
    ///    loopback pipeline entirely (see `LoadOptions.nativeRemoteHLS`):
    ///    AVPlayer manages the live edge, buffering, and reconnect itself.
    ///    The source live container (e.g. `hls`) isn't in our DirectPlay set,
    ///    so the server repackages regardless; we steer that to native HLS
    ///    rather than the progressive TS the engine used to consume.
    ///
    /// 2. **No bitrate cap below source.** We want the server to STREAM-COPY
    ///    the video into the HLS segments (no re-encode), not downscale it. A
    ///    cap below the source bitrate silently forces a video re-encode even
    ///    when the only transcode reason is the container. Keeping the ceiling
    ///    high lets the probed H.264 copy through: cheap on the server, no
    ///    quality loss. The `liveReencodeCapBitrate` only applies on the
    ///    re-encode fallback (probe reports `VideoCodecNotSupported`).
    static func liveProfile() -> [String: Any] {
        var profile = current()
        profile["MaxStreamingBitrate"] = liveCopyCeilingBitrate
        profile["MaxStaticBitrate"] = liveCopyCeilingBitrate
        // Copy-friendly HLS transcoding profile: accept h264/hevc for copy,
        // request the HLS sub-protocol so the client plays the m3u8 natively,
        // and impose NO bitrate cap so the server prefers `-c:v copy` over a
        // downscale re-encode when the probed source codec is compatible.
        profile["TranscodingProfiles"] = [
            [
                "Type": "Video",
                "Container": "ts",
                "Protocol": "hls",
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
