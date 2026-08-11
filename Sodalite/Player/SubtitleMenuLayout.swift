import Foundation
import AetherEngine

/// One row of the in-player subtitle menu.
enum SubtitleMenuRow: Equatable {
    /// Pinned header opening the secondary-track submenu (VOD only).
    case secondaryHeader
    case off
    /// A selectable track, carrying the stream index the engine expects back.
    case track(streamIndex: Int)
    /// Pinned footer opening the online search (VOD only).
    case searchOnline
}

/// The subtitle menu's row order, in one place.
///
/// It used to live as magic indices in four spots at once (the item builder, the highlight
/// navigation, the Select commit and hold-to-delete), plus a fifth in `openSubtitleDropdown` that
/// still counted on the older layout without the secondary header, so opening the menu with a track
/// active highlighted the row above it. Live TV then needs a different row set entirely, which is
/// what forced the question: a layout described in five places cannot grow a second shape.
enum SubtitleMenuLayout {
    static func rows(streams: [MediaStream],
                     supportsSecondary: Bool,
                     supportsSearch: Bool) -> [SubtitleMenuRow] {
        var rows: [SubtitleMenuRow] = []
        if supportsSecondary { rows.append(.secondaryHeader) }
        rows.append(.off)
        rows += streams.map { .track(streamIndex: $0.index) }
        if supportsSearch { rows.append(.searchOnline) }
        return rows
    }

    /// Row the menu should open on: the active track, else "Off". Never a pinned header, which is a
    /// submenu door rather than a selection.
    static func highlightIndex(forActive activeSubtitleIndex: Int?, in rows: [SubtitleMenuRow]) -> Int {
        if let activeSubtitleIndex,
           let index = rows.firstIndex(of: .track(streamIndex: activeSubtitleIndex)) {
            return index
        }
        return rows.firstIndex(of: .off) ?? 0
    }
}
