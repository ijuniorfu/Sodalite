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

extension JellyfinProgram {
    /// nil when either end is missing, which is what the row-wide fallback keys off.
    var guideTimeRange: GuideTimeRange? {
        guard let startDate, let endDate else { return nil }
        return GuideTimeRange(start: startDate, end: endDate)
    }
}
