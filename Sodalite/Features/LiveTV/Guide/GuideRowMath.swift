import Foundation
import CoreGraphics

/// A program's airtime, reduced to what the row geometry needs.
struct GuideTimeRange: Equatable, Sendable {
    let start: Date
    let end: Date
}

/// Overlap resolution for one channel's programs.
///
/// EPG data is not guaranteed to be disjoint. IPTV providers routinely ship a channel whose
/// programs overlap, and drawn literally that stacks two cells on the same pixels: the one behind
/// is invisible but still focusable, so focus lands on a program the user cannot see and the one on
/// top looks like it has a rounded blob poking out beside it.
enum GuideRowMath {

    /// Indices to keep, in order. An entry that ends no later than something already kept is fully
    /// covered, carries nothing the row does not already show, and is dropped so it can never take
    /// focus. Entries without airtimes are kept: they render as the row-wide fallback.
    ///
    /// Expects `ranges` sorted by start.
    static func keptIndices(_ ranges: [GuideTimeRange?]) -> [Int] {
        var kept: [Int] = []
        var cursor = Date.distantPast
        for (index, range) in ranges.enumerated() {
            guard let range else {
                kept.append(index)
                continue
            }
            guard range.end > cursor else { continue }
            kept.append(index)
            cursor = max(cursor, range.end)
        }
        return kept
    }

    /// Content-space x and width per entry, with partial overlaps trimmed: an entry that starts
    /// before its predecessor ends begins where the predecessor ends instead. The times shown in the
    /// cell stay the program's own, only the geometry moves, so a trimmed program still reads
    /// truthfully while the row keeps one cell per column of pixels.
    ///
    /// Expects `ranges` sorted by start, and already filtered through `keptIndices`.
    static func spans(_ ranges: [GuideTimeRange?], axis: GuideAxis) -> [(x: CGFloat, width: CGFloat)] {
        var result: [(x: CGFloat, width: CGFloat)] = []
        var cursor: CGFloat = 0
        for range in ranges {
            guard let range else {
                result.append((0, axis.totalWidth))
                cursor = axis.totalWidth
                continue
            }
            let rawX = max(0, axis.x(for: range.start))
            let right = rawX + axis.width(from: range.start, to: range.end)
            let x = max(rawX, cursor)
            result.append((x, max(0, right - x)))
            cursor = max(cursor, right)
        }
        return result
    }
}

extension GuideRowMath {
    /// Content offset that makes a focused span readable, or nil when it already is.
    ///
    /// Vertical moves in the grid keep the time position rather than following the cell, so focus
    /// can land on a program that only just reaches into the viewport. The focus engine does not
    /// scroll for that: the program shows as a rounded stub at the very edge while the hero
    /// describes it in full.
    static func offsetToReveal(span: (x: CGFloat, width: CGFloat),
                               offset: CGFloat,
                               viewport: CGFloat,
                               minimumVisible: CGFloat,
                               maxOffset: CGFloat) -> CGFloat? {
        guard span.width > 0, viewport > 0 else { return nil }
        let visible = min(span.x + span.width, offset + viewport) - max(span.x, offset)
        // A cell narrower than the threshold only has to be fully visible.
        guard visible < min(span.width, minimumVisible) else { return nil }
        // Reached from the left: start it where a jump would. From the right: pull its end in, so a
        // long block does not scroll the user past everything they were looking at.
        let target = span.x < offset
            ? span.x - viewport * 0.08
            : span.x + span.width - viewport * 0.92
        let clamped = min(max(0, target), maxOffset)
        return abs(clamped - offset) > 1 ? clamped : nil
    }
}

extension JellyfinProgram {
    /// nil when either end is missing, which is what the row-wide fallback keys off.
    var guideTimeRange: GuideTimeRange? {
        guard let startDate, let endDate else { return nil }
        return GuideTimeRange(start: startDate, end: endDate)
    }
}
