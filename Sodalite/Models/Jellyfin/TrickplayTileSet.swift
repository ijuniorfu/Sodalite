import Foundation
import CoreGraphics

/// Resolves a scrub time to a Jellyfin trickplay tile index + the crop rect of the thumbnail
/// inside that sprite. Pure value type, no I/O. Built once per session from the item's manifest.
struct TrickplayTileSet: Equatable, Sendable {
    let width: Int
    let info: TrickplayInfo

    /// Picks the rendition whose width is closest to `targetWidth`. nil when the item has no
    /// trickplay for `mediaSourceID` (or any source as a fallback) or no parseable width keys.
    init?(trickplay: [String: [String: TrickplayInfo]]?, mediaSourceID: String?, targetWidth: Int) {
        guard let trickplay, !trickplay.isEmpty else { return nil }
        let renditions = mediaSourceID.flatMap { trickplay[$0] } ?? trickplay.first?.value
        guard let renditions, !renditions.isEmpty else { return nil }
        let pick = renditions
            .compactMap { key, value -> (Int, TrickplayInfo)? in
                guard let w = Int(key), w > 0 else { return nil }
                return (w, value)
            }
            .min { abs($0.0 - targetWidth) < abs($1.0 - targetWidth) }
        guard let pick else { return nil }
        self.width = pick.0
        self.info = pick.1
    }

    /// (tileIndex, crop). Thumbnail index = floor(ms / interval), clamped to thumbnailCount-1.
    /// A tile holds tileWidth x tileHeight thumbnails laid out row-major.
    func tile(forSeconds seconds: Double) -> (tileIndex: Int, crop: CGRect)? {
        guard info.interval > 0, info.tileWidth > 0, info.tileHeight > 0,
              info.width > 0, info.height > 0, info.thumbnailCount > 0 else { return nil }
        let ms = max(0, seconds) * 1000
        let rawThumb = Int(ms / Double(info.interval))
        let thumb = min(rawThumb, info.thumbnailCount - 1)
        let perTile = info.tileWidth * info.tileHeight
        let tileIndex = thumb / perTile
        let within = thumb % perTile
        let col = within % info.tileWidth
        let row = within / info.tileWidth
        let crop = CGRect(x: col * info.width, y: row * info.height,
                          width: info.width, height: info.height)
        return (tileIndex, crop)
    }
}
