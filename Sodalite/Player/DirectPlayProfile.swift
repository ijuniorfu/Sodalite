import Foundation
import AetherEngine

/// Jellyfin device profile for AetherEngine on Apple TV. Engine demuxes
/// MKV/MP4/AVI/TS/VOB/3GP/M2TS via FFmpeg, dispatching to native AVPlayer HLS
/// (HEVC, H.264, AV1+HW) or SW pipeline (AV1 no-HW, VP9, MPEG-4 Part 2,
/// MPEG-2, VC-1); server transcodes only codecs outside this set. One
/// `baseProfile()` (HDR/SDR split lives at the engine `displayCapabilities`
/// level, not the server-facing profile; HDR direct-plays on SDR via VideoToolbox).
@MainActor
enum DirectPlayProfile {

    static func current() -> [String: Any] {
        #if DEBUG
        let caps = AetherEngine.displayCapabilities
        print("[Profile] Display: HDR=\(caps.supportsHDR) DV=\(caps.supportsDolbyVision) HDR10=\(caps.supportsHDR10) HLG=\(caps.supportsHLG)")
        #endif
        return baseProfile()
    }

    /// Live stream-copy ceiling: kept at the VOD direct-play ceiling so any
    /// broadcast H.264/HEVC stays under it and Jellyfin copies the bitstream.
    /// Doubles as the encoder target for genuinely incompatible channels (e.g.
    /// MPEG-2 OTA), which would need a separate per-codec re-encode cap.
    static let liveCopyCeilingBitrate = 200_000_000

    /// Bounded encoder target (re-encode) for channels whose source codec is
    /// NOT in liveProfile's VideoCodec list (Jellyfin reports
    /// VideoCodecNotSupported). MaxStreamingBitrate doubles as the encoder
    /// target, so probing at the 200 Mbps ceiling makes the server answer
    /// HTTP 500 (device-verified on "Infomercial"). 12 Mbps = sane 1080p H.264.
    static let liveReencodeCapBitrate = 12_000_000

    /// Live TV profile. Protocol=http/Container=ts: progressive MPEG-TS (not
    /// HLS) consumed by AetherEngine's AVIOReader; engine demuxes + dispatches
    /// every live codec with no server re-encode. Full copy codec list + high
    /// MaxStreamingBitrate keep Jellyfin stream-copying instead of downscaling.
    static func liveProfile() -> [String: Any] {
        var profile = current()
        profile["MaxStreamingBitrate"] = liveCopyCeilingBitrate
        profile["MaxStaticBitrate"] = liveCopyCeilingBitrate
        // VideoCodec = every engine-decodable codec MPEG-TS can legally carry.
        // Do NOT add av1/vp9/vp8: ffmpeg's mpegts muxer rejects them and
        // Jellyfin then answers HTTP 400 on every transcode URL, breaking all
        // non-DirectPlay channels (device-verified: NBC 1 400'd the moment
        // av1,vp9,vp8 were added). Such channels need a SEPARATE
        // TranscodingProfile (e.g. matroska); a codec outside this list reports
        // VideoCodecNotSupported and takes the 12 Mbps re-encode in loadLiveStream.
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

    static func baseProfile() -> [String: Any] {
        [
            "MaxStreamingBitrate": 200_000_000,
            "MaxStaticBitrate": 200_000_000,
            "MusicStreamingTranscodingBitrate": 384_000,

            // VideoCodec list matches the engine dispatch table in
            // AetherEngine.swift; listing them stops Jellyfin transcoding
            // XVID/DivX, MPEG-2 remuxes, and VC-1 BD rips.
            "DirectPlayProfiles": [
                [
                    "Container": "mp4,m4v,mov,mkv,matroska,avi,mpegts,ts,m2ts,mts,3gp,3g2,vob,ogg,webm,flv",
                    "Type": "Video",
                    "VideoCodec": "h264,hevc,av1,vp9,vp8,mpeg4,mpeg2video,vc1",
                    // DTS spelled every way Jellyfin reports it (dts/dca/dts-hd
                    // vary by build) so it won't transcode DTS-HD MA over a
                    // string mismatch. mp2 pairs with MPEG-2 (broadcast/VOB).
                    "AudioCodec": "aac,ac3,eac3,mp3,mp2,flac,opus,vorbis,alac,truehd,mlp,dts,dca,dts-hd,dtshd,pcm_s16le,pcm_s24le,pcm_f32le",
                ],
                [
                    "Container": "mp3,aac,m4a,m4b,flac,alac,wav,opus,ogg",
                    "Type": "Audio",
                ],
            ] as [[String: Any]],

            // Fallback: progressive MP4 over HTTP (not HLS): engine's custom
            // AVIO/URLSession context doesn't support HLS playlists.
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

    /// All formats delivered External (fetched as SRT via Jellyfin's subtitle
    /// API) so an "unsupported" subtitle codec never forces a video transcode.
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
