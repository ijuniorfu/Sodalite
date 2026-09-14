import SwiftUI

/// Everything a detail page can say about the copy it is describing, as data rather than as a view
/// (Sodalite#146).
///
/// It replaces the four-card `TechInfoBox` strip, which cost about a third of a screen and four
/// focus stops on the page itself, for facts most viewers want once. Since Sodalite#145 the ones
/// they want at a glance (resolution, dynamic range, audio) are badges in the hero, so what is left
/// here is the long tail: framerate, codec profile, per-track audio and the full subtitle list. That
/// belongs behind More Details.
///
/// A value type because two surfaces read it now, the overlay and the one-line file caption at the
/// bottom of the page, and because the extraction is the part worth testing.
struct TechFacts: Equatable {

    /// A fixed label comes from the catalog; a track's own name comes from the file and is already
    /// in whatever language the muxer wrote, so it is never looked up.
    enum RowLabel: Equatable {
        case key(LocalizedStringKey)
        case verbatim(String)
    }

    struct Row: Equatable, Identifiable {
        let id: String
        let label: RowLabel
        let value: String
    }

    struct Section: Equatable, Identifiable {
        let id: String
        let icon: String
        let title: LocalizedStringKey
        let rows: [Row]
    }

    let sections: [Section]

    /// The one-line caption for the bottom of the page, after Infuse: filename, size, video codec,
    /// audio codec and layout, bitrate. nil when the server told us nothing worth a line.
    let caption: String?

    var isEmpty: Bool { sections.isEmpty && caption == nil }

    // MARK: - Extraction

    /// `sourceID` is the version the page is showing. Without it a multi-version item describes its
    /// first source while the viewer is looking at the one they picked, which is Sodalite#139 again.
    static func resolve(item: JellyfinItem, sourceID: String?) -> TechFacts {
        let streams = item.effectiveMediaStreams(id: sourceID) ?? []
        let video = streams.first { $0.type == .video }
        let audioStreams = streams.filter { $0.type == .audio }
        let subtitleStreams = streams.filter { $0.type == .subtitle }
        let source = item.effectiveMediaSource(id: sourceID)

        var sections: [Section] = []

        if let video {
            var rows: [Row] = []
            if let w = video.width, let h = video.height {
                rows.append(Row(id: "resolution", label: .key("detail.tech.resolution"), value: "\(w)×\(h)"))
            }
            if let codec = video.codec?.uppercased() {
                let profile = video.profile ?? ""
                rows.append(Row(id: "codec", label: .key("detail.tech.codec"),
                                value: profile.isEmpty ? codec : "\(codec) \(profile)"))
            }
            if let fps = video.realFrameRate ?? video.averageFrameRate {
                rows.append(Row(id: "framerate", label: .key("detail.tech.framerate"),
                                value: String(format: "%.2g fps", fps)))
            }
            if let range = dynamicRangeLabel(video) {
                rows.append(Row(id: "dynamicRange", label: .key("detail.tech.dynamicRange"), value: range))
            }
            if !rows.isEmpty {
                sections.append(Section(id: "video", icon: "film", title: "detail.tech.video", rows: rows))
            }
        }

        // Every audio track, not just the first: which languages a file carries is the question a
        // track list answers, and the strip could only ever show one of them.
        if !audioStreams.isEmpty {
            var rows: [Row] = []
            for (index, audio) in audioStreams.enumerated() {
                var parts: [String] = []
                if let codec = audio.codec?.uppercased() { parts.append(codec) }
                if let channels = audio.channels { parts.append(channelLayout(channels)) }
                let value = parts.joined(separator: " · ")
                let name = audio.displayTitle ?? audio.language
                rows.append(Row(id: "audio-\(index)",
                                label: name.map { RowLabel.verbatim($0) } ?? .key("detail.tech.audio"),
                                value: value))
            }
            sections.append(Section(id: "audio", icon: "speaker.wave.2", title: "detail.tech.audio", rows: rows))
        }

        if let source {
            var rows: [Row] = []
            if let container = source.container?.uppercased() {
                rows.append(Row(id: "format", label: .key("detail.tech.format"), value: container))
            }
            if let bitrate = source.bitrate {
                rows.append(Row(id: "bitrate", label: .key("detail.tech.bitrate"), value: formatBitrate(bitrate)))
            }
            if let size = source.size {
                rows.append(Row(id: "size", label: .key("detail.tech.size"), value: formatFileSize(size)))
            }
            if let name = filename(of: source) {
                rows.append(Row(id: "filename", label: .key("detail.tech.filename"), value: name))
            }
            if !rows.isEmpty {
                sections.append(Section(id: "file", icon: "doc", title: "detail.tech.file", rows: rows))
            }
        }

        // The full list, where the strip stopped at four. This is the one place in the app that can
        // answer "does this file carry a forced Danish track" before playback starts.
        if !subtitleStreams.isEmpty {
            let rows = subtitleStreams.enumerated().map { index, sub in
                Row(id: "subtitle-\(index)",
                    label: .verbatim(sub.displayTitle ?? sub.language ?? "—"),
                    value: sub.isForced == true
                        ? String(localized: "tech.subtitles.forced", defaultValue: "F")
                        : "")
            }
            sections.append(Section(id: "subtitles", icon: "captions.bubble",
                                    title: "detail.tech.subtitles", rows: rows))
        }

        return TechFacts(sections: sections,
                         caption: captionLine(source: source, video: video, audio: audioStreams.first))
    }

    /// filename · size · video codec · audio codec and layout · bitrate. Whatever the server holds,
    /// which in practice is the short form rather than a full release name.
    private static func captionLine(source: MediaSource?, video: MediaStream?, audio: MediaStream?) -> String? {
        guard let source else { return nil }
        var parts: [String] = []
        if let name = filename(of: source) { parts.append(name) }
        if let size = source.size { parts.append(formatFileSize(size)) }
        if let codec = video?.codec?.uppercased() { parts.append(codec) }
        if let codec = audio?.codec?.uppercased() {
            if let channels = audio?.channels {
                parts.append("\(codec) \(channelLayout(channels))")
            } else {
                parts.append(codec)
            }
        }
        if let bitrate = source.bitrate { parts.append(formatBitrate(bitrate)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func filename(of source: MediaSource) -> String? {
        guard let path = source.path, let name = path.split(separator: "/").last else { return nil }
        return String(name)
    }

    /// The version the page is describing, for the line under the overlay's heading. Nil unless the
    /// item offers a choice: one file needs no caption, and a caption that can only ever repeat
    /// itself is noise.
    ///
    /// The server's version name carries the line where there is one. The derived specs do not
    /// repeat here, they are the fallback for a source the server never named, so the line is never
    /// blank (Sodalite#139).
    static func versionSubtitle(for item: JellyfinItem, sourceID: String?) -> String? {
        guard VersionSelection.isOffered(for: item),
              let source = item.effectiveMediaSource(id: sourceID) else { return nil }
        let name = source.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let line = name.isEmpty ? source.versionLabel : name
        return line.isEmpty ? nil : line
    }

    // MARK: - Formatters

    /// Matches the player stats overlay: DV P<profile>, then VideoRangeType, falling back to the raw
    /// VideoRange string.
    static func dynamicRangeLabel(_ video: MediaStream) -> String? {
        if let dv = video.dvProfile {
            return "Dolby Vision P\(dv)"
        }
        switch video.videoRangeType?.uppercased() {
        case "HDR10":     return "HDR10"
        case "HDR10PLUS": return "HDR10+"
        case "HLG":       return "HLG"
        case "DOVI", "DOVIWITHHDR10", "DOVIWITHHLG", "DOVIWITHSDR":
            return "Dolby Vision"
        case "SDR":       return "SDR"
        default:          return video.videoRange
        }
    }

    static func channelLayout(_ channels: Int) -> String {
        switch channels {
        case 1: String(localized: "tech.channels.mono", defaultValue: "Mono")
        case 2: String(localized: "tech.channels.stereo", defaultValue: "Stereo")
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels)ch"
        }
    }

    static func formatBitrate(_ bps: Int) -> String {
        let mbps = Double(bps) / 1_000_000
        if mbps >= 1 { return String(format: "%.1f Mbps", mbps) }
        return "\(bps / 1000) Kbps"
    }

    static func formatFileSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
