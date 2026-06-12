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
/// There used to be two flavors keyed on display capabilities
/// (permissive HDR vs conservative SDR), but they converged to the
/// byte-identical dictionary once HDR sources were direct-played on
/// SDR panels too (VideoToolbox converts), and the duplicate copies
/// had already started drifting in their comments. One `baseProfile()`
/// now; the HDR/SDR split stays real at the ENGINE level
/// (`AetherEngine.displayCapabilities` drives display criteria), just
/// not in the server-facing profile.
@MainActor
enum DirectPlayProfile {

    /// The device profile shipped with every PlaybackInfo request.
    static func current() -> [String: Any] {
        #if DEBUG
        let caps = AetherEngine.displayCapabilities
        print("[Profile] Display: HDR=\(caps.supportsHDR) DV=\(caps.supportsDolbyVision) HDR10=\(caps.supportsHDR10) HLG=\(caps.supportsHLG)")
        #endif
        return baseProfile()
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

    /// Bounded encoder target for the rare channel whose source video codec
    /// is NOT in the engine-decode copy list (liveProfile's VideoCodec),
    /// i.e. Jellyfin reports VideoCodecNotSupported and must really
    /// re-encode. The PlaybackInfo MaxStreamingBitrate doubles as the
    /// encoder target on re-encode, so probing such a channel at the
    /// 200 Mbps copy ceiling asks the server for an absurd real-time
    /// encode and it answers HTTP 500 (device-verified on "Infomercial",
    /// again after the engine-decode migration dropped the two-stage
    /// negotiation). 12 Mbps is a sane real-time 1080p H.264 target.
    static let liveReencodeCapBitrate = 12_000_000

    /// Profile for live TV channels. Two things differ from VOD:
    ///
    /// 1. **Protocol=http, Container=ts.** We request a progressive MPEG-TS
    ///    stream (not an HLS wrapper) that AetherEngine's AVIOReader consumes
    ///    as a continuous forward-only source, exactly like VOD. The engine
    ///    demuxes the TS itself and dispatches h264/hevc to the native AVPlayer
    ///    loopback and MPEG-2 / VC-1 / MPEG-4 Part 2 to the SW decoder, so every
    ///    live codec plays with no server re-encode.
    ///
    /// 2. **Full copy codec list + no bitrate cap below source.** Listing every
    ///    source video codec tells Jellyfin to STREAM-COPY whatever the channel
    ///    is (container remux only, no video re-encode), since the engine
    ///    decodes it. The high `MaxStreamingBitrate` keeps the server copying
    ///    rather than downscaling. mp2 audio pairs with MPEG-2 broadcast sources.
    static func liveProfile() -> [String: Any] {
        var profile = current()
        profile["MaxStreamingBitrate"] = liveCopyCeilingBitrate
        profile["MaxStaticBitrate"] = liveCopyCeilingBitrate
        // Progressive MPEG-TS over HTTP (NOT hls): the engine ingests + decodes
        // the raw stream. The video codec list is every engine-decodable codec
        // that MPEG-TS can legally CARRY. Do NOT add av1/vp9/vp8 here even
        // though the engine decodes them (dav1d / SW pipeline): MPEG-TS has no
        // mapping for those codecs (ffmpeg's mpegts muxer rejects them), and
        // listing them made Jellyfin answer HTTP 400 on EVERY transcode
        // stream URL, breaking all non-DirectPlay channels (device-verified:
        // NBC 1 played with this exact list, then 400'd the moment
        // av1,vp9,vp8 were added, even on the HEAD probe). If a vp9/av1 IPTV
        // channel ever shows up, it needs a SEPARATE TranscodingProfile with
        // a container that can host them (e.g. matroska), not this one. A
        // codec outside this list reports VideoCodecNotSupported and takes
        // the bounded 12 Mbps re-encode via the two-stage negotiation in
        // loadLiveStream.
        profile["TranscodingProfiles"] = [
            [
                "Type": "Video",
                "Container": "ts",
                "Protocol": "http",
                "VideoCodec": "h264,hevc,mpeg2video,vc1,mpeg4",
                "AudioCodec": "aac,ac3,eac3,mp3,mp2",
                "Context": "Streaming",
            ],
        ] as [[String: Any]]
        return profile
    }

    // MARK: - Base profile

    /// AetherEngine handles HEVC Main10, HDR10, Dolby Vision (Profile
    /// 5/8.1/8.4), HLG, and multichannel audio; HDR sources direct-play
    /// on SDR panels too (VideoToolbox converts). Server only has to
    /// remux containers, no re-encoding; server-side transcoding is the
    /// absolute last resort.
    static func baseProfile() -> [String: Any] {
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
