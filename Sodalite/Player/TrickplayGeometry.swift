import CoreGraphics
import Foundation

/// Pure trickplay coordinate math. Given a `TrickplayInfo` it maps a
/// playback time to the tile-sheet index that holds that frame and the
/// crop rectangle of the frame inside that sheet. No I/O, no state, so
/// it can be reasoned about (and exercised) in isolation.
struct TrickplayGeometry: Equatable {
    let width: Int
    let info: TrickplayInfo

    /// Thumbnails packed into one sheet.
    var tilesPerSheet: Int { max(1, info.tileWidth * info.tileHeight) }

    /// Clamp the manifest to something usable. A zero interval or zero
    /// thumbnail count means the manifest is unusable and the caller
    /// should treat the item as having no trickplay.
    var isUsable: Bool { info.interval > 0 && info.thumbnailCount > 0 && info.width > 0 && info.height > 0 }

    /// Global thumbnail index for a playback time, clamped to the last
    /// available thumbnail.
    func thumbnailIndex(forSeconds seconds: Double) -> Int {
        guard info.interval > 0 else { return 0 }
        let raw = Int((seconds * 1000.0) / Double(info.interval))
        return max(0, min(raw, info.thumbnailCount - 1))
    }

    /// Which sheet holds a given thumbnail.
    func sheetIndex(forThumbnail thumb: Int) -> Int { thumb / tilesPerSheet }

    /// Crop rectangle (sheet pixel space, origin top-left) of a thumbnail
    /// inside its sheet.
    func cropRect(forThumbnail thumb: Int) -> CGRect {
        let pos = thumb % tilesPerSheet
        let col = pos % info.tileWidth
        let row = pos / info.tileWidth
        return CGRect(
            x: CGFloat(col * info.width),
            y: CGFloat(row * info.height),
            width: CGFloat(info.width),
            height: CGFloat(info.height)
        )
    }

    /// Pick a trickplay resolution from an item manifest for a given
    /// media source. Prefers the largest width at or below `targetWidth`
    /// (480 is plenty for a scrub card and keeps sheets light); if every
    /// available width is larger, takes the smallest. Returns nil when
    /// no usable manifest exists.
    static func best(
        from trickplay: [String: [String: TrickplayInfo]]?,
        mediaSourceID: String,
        targetWidth: Int = 480
    ) -> TrickplayGeometry? {
        guard let perSource = trickplay?[mediaSourceID], !perSource.isEmpty else { return nil }
        let parsed = perSource
            .compactMap { key, info -> (Int, TrickplayInfo)? in
                guard let w = Int(key) else { return nil }
                return (w, info)
            }
            .sorted { $0.0 < $1.0 }
        guard !parsed.isEmpty else { return nil }
        let pick = parsed.last(where: { $0.0 <= targetWidth }) ?? parsed.first!
        let geometry = TrickplayGeometry(width: pick.0, info: pick.1)
        return geometry.isUsable ? geometry : nil
    }
}
