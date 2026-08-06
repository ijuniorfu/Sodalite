import Foundation
import CoreGraphics

/// The guide's time axis: every conversion between a wall-clock moment and a horizontal offset.
/// Pure and calendar-injectable so the grid, the ruler and the focus anchor cannot drift apart,
/// and so the mathematics is testable without a server.
struct GuideAxis: Equatable, Sendable {
    /// Left edge, `now` floored to the previous :00 or :30 so cells line up with the ruler.
    let start: Date
    /// Right edge: `start + span`, shortened when the server's guide data ends earlier.
    let end: Date
    /// Horizontal scale.
    let pointsPerMinute: CGFloat

    /// 48h, so "tomorrow 20:15" is reachable from an evening start. 24h is not.
    static let defaultSpan: TimeInterval = 48 * 3600
    /// Grid slot in minutes. Ruler chips are exactly one slot wide, so chip edges meet gridlines.
    static let slotMinutes: Int = 30

    init(now: Date,
         pointsPerMinute: CGFloat,
         guideEnd: Date? = nil,
         span: TimeInterval = GuideAxis.defaultSpan,
         calendar: Calendar = .current) {
        let flooredStart = Self.floorToSlot(now, calendar: calendar)
        let uncapped = flooredStart.addingTimeInterval(span)
        start = flooredStart
        // A server with 12h of EPG data should render a 12h axis, not 36h of empty canvas. The
        // ceiling keeps the axis a whole number of slots, which is what lets the ruler and the grid
        // share one content width and copy scroll offsets straight across.
        if let guideEnd, guideEnd > flooredStart, guideEnd < uncapped {
            end = Self.ceilToSlot(guideEnd, calendar: calendar)
        } else {
            end = uncapped
        }
        self.pointsPerMinute = pointsPerMinute
    }

    static func floorToSlot(_ date: Date, calendar: Calendar = .current) -> Date {
        let minute = calendar.component(.minute, from: date)
        var comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        comps.minute = minute < slotMinutes ? 0 : slotMinutes
        return calendar.date(from: comps) ?? date
    }

    static func ceilToSlot(_ date: Date, calendar: Calendar = .current) -> Date {
        let floored = floorToSlot(date, calendar: calendar)
        return floored == date ? date : floored.addingTimeInterval(TimeInterval(slotMinutes) * 60)
    }

    var slotWidth: CGFloat { CGFloat(Self.slotMinutes) * pointsPerMinute }

    var totalWidth: CGFloat {
        CGFloat(end.timeIntervalSince(start) / 60) * pointsPerMinute
    }

    func x(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(start) / 60) * pointsPerMinute
    }

    func date(atX x: CGFloat) -> Date {
        start.addingTimeInterval(Double(x / pointsPerMinute) * 60)
    }

    /// Visible width of a program, clamped to the axis. Zero when it does not reach into the window.
    func width(from programStart: Date, to programEnd: Date) -> CGFloat {
        let visibleStart = max(programStart, start)
        let visibleEnd = min(programEnd, end)
        return CGFloat(max(0, visibleEnd.timeIntervalSince(visibleStart) / 60)) * pointsPerMinute
    }

    func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// Slot boundaries: the ruler's chips and the grid's vertical lines, from one source.
    var slots: [Date] {
        var result: [Date] = []
        var cursor = start
        let step = TimeInterval(Self.slotMinutes) * 60
        while cursor < end {
            result.append(cursor)
            cursor = cursor.addingTimeInterval(step)
        }
        return result
    }

    /// 20:15 on the day `days` after `reference`. nil when that moment is already past or falls
    /// outside the axis, so the caller hides the chip rather than offering a dead jump.
    func primeTime(days: Int, from reference: Date, calendar: Calendar = .current) -> Date? {
        // Built from the target day's components, NOT date(bySettingHour:of:), which searches
        // forward: past 20:15 it silently answers with the NEXT day, so "tonight" would mean
        // tomorrow and "tomorrow" the day after.
        guard let day = calendar.date(byAdding: .day, value: days, to: reference) else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = 20
        components.minute = 15
        guard let candidate = calendar.date(from: components),
              candidate > reference,
              contains(candidate)
        else { return nil }
        return candidate
    }
}
