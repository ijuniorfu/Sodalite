import SwiftUI

// MARK: - MediaSource display helpers

extension MediaSource {
    /// Primary video stream, used to derive resolution and codec labels.
    var primaryVideoStream: MediaStream? {
        mediaStreams?.first { $0.type == .video }
    }

    /// "4K" / "1440p" / "1080p" etc. derived from the video stream
    /// dimensions. Normalizes height to a 16:9-equivalent width so a
    /// 2.39:1 scope master (height < 1080) still reads as the right tier.
    var resolutionLabel: String? {
        guard let v = primaryVideoStream else { return nil }
        let w = v.width ?? 0
        let h = v.height ?? 0
        let dim = max(w, h * 16 / 9)
        switch dim {
        case 3840...: return "4K"
        case 2560...: return "1440p"
        case 1920...: return "1080p"
        case 1280...: return "720p"
        default: return h > 0 ? "\(h)p" : nil
        }
    }

    /// Uppercased video codec, e.g. "HEVC", "H264", "AV1".
    var codecLabel: String? {
        primaryVideoStream?.codec?.uppercased()
    }

    /// Human file size, e.g. "82 GB".
    var sizeLabel: String? {
        guard let size, size > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Display label for a version row. Prefers the server's version
    /// name (Jellyfin fills `MediaSource.Name` with the file's version
    /// tag, e.g. "1080p" / "Directors Cut", for multi-version items),
    /// then appends any derived specs the name doesn't already convey.
    /// Falls back to container so a row is never blank.
    var versionLabel: String {
        var parts: [String] = []
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(name)
        }
        for spec in [resolutionLabel, codecLabel, sizeLabel].compactMap({ $0 }) {
            if !parts.contains(where: { $0.caseInsensitiveCompare(spec) == .orderedSame }) {
                parts.append(spec)
            }
        }
        if parts.isEmpty, let container, !container.isEmpty {
            parts.append(container.uppercased())
        }
        return parts.joined(separator: " · ")
    }

    /// Sort key for "highest quality first": bitrate, else pixel count.
    var qualityRank: Int {
        if let bitrate, bitrate > 0 { return bitrate }
        let v = primaryVideoStream
        return (v?.width ?? 0) * (v?.height ?? 0)
    }
}

// MARK: - Version picker presentation payload

/// Drives the version sheet via `.sheet(item:)`. Carrying the sources in
/// the presented item (instead of a separate `@State` array read by a
/// `.sheet(isPresented:)` content closure) avoids SwiftUI's stale-content
/// race, where the closure captures the initial empty array and the sheet
/// renders with zero sources.
struct VersionPickerChoice: Identifiable {
    let id = UUID()
    /// The item to play (a movie, or the chosen episode for series).
    let item: JellyfinItem
    let sources: [MediaSource]
    let fromBeginning: Bool
    /// Series-only: preserves the focus-restoration origin flag. Ignored
    /// by movie detail.
    let fromPlayButton: Bool
}

// MARK: - Version picker sheet

/// Shown from the detail views when an item has more than one media
/// source. Lists the versions (highest quality first, top one focused),
/// and calls `onSelect` with the chosen source. Dismissing without a
/// selection cancels playback (the caller starts nothing).
struct VersionPickerSheet: View {
    let sources: [MediaSource]
    let tintColor: Color?
    let onSelect: (MediaSource) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedID: String?

    private var sorted: [MediaSource] {
        sources.sorted { $0.qualityRank > $1.qualityRank }
    }

    var body: some View {
        VStack(spacing: 36) {
            Text("detail.version.title")
                .font(.title2)
                .fontWeight(.semibold)

            ScrollView {
                VStack(spacing: 16) {
                    ForEach(sorted) { source in
                        row(source)
                    }
                }
                .frame(
                    maxWidth: 760,
                    minHeight: sorted.count > 1
                        ? min(CGFloat(sorted.count) * 140, 720)
                        : nil
                )
                .padding(.vertical, 8)
            }
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial)
        .onAppear { focusedID = sorted.first?.id }
    }

    private func row(_ source: MediaSource) -> some View {
        let isFocused = focusedID == source.id
        return HStack {
            Text(source.versionLabel)
                .font(.body)
                .fontWeight(.medium)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isFocused ? (tintColor ?? .accentColor) : Color.Theme.surface)
        )
        .foregroundStyle(isFocused ? Color.black : Color.primary)
        .focusable(true)
        .focused($focusedID, equals: source.id)
        .stableTap(isFocused: isFocused) {
            onSelect(source)
            dismiss()
        }
    }
}
