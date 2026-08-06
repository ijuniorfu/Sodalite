import Testing
import Foundation
@testable import Sodalite

/// The guide's time mathematics. Everything the grid, the ruler and the anchor agree on lives in
/// `GuideAxis`, so it is worth pinning down without a server in the loop.
struct GuideAxisTests {

    /// Fixed calendar so a machine in another zone cannot move the slot boundaries.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return cal
    }

    private func date(_ hour: Int, _ minute: Int, day: Int = 4) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }

    private func axis(now: Date, guideEnd: Date? = nil) -> GuideAxis {
        GuideAxis(now: now, pointsPerMinute: 8, guideEnd: guideEnd, calendar: calendar)
    }

    @Test("start floors to the previous half hour")
    func startFloors() {
        #expect(axis(now: date(17, 29)).start == date(17, 0))
        #expect(axis(now: date(17, 30)).start == date(17, 30))
        #expect(axis(now: date(17, 59)).start == date(17, 30))
        #expect(axis(now: date(17, 0)).start == date(17, 0))
    }

    @Test("the default span is 48 hours so tomorrow evening is reachable")
    func defaultSpan() {
        let a = axis(now: date(19, 0))
        #expect(a.end == date(19, 0).addingTimeInterval(48 * 3600))
        #expect(a.totalWidth == CGFloat(48 * 60 * 8))
    }

    @Test("x and date are inverses, and zero sits at the axis start")
    func offsetRoundTrip() {
        let a = axis(now: date(17, 0))
        #expect(a.x(for: a.start) == 0)
        #expect(a.x(for: date(18, 0)) == CGFloat(60 * 8))
        #expect(a.date(atX: CGFloat(60 * 8)) == date(18, 0))
    }

    @Test("width clamps to the axis at both ends")
    func widthClamps() {
        let a = axis(now: date(17, 0))
        // Straddling the start: only the part inside the axis counts.
        #expect(a.width(from: date(16, 30), to: date(17, 30)) == CGFloat(30 * 8))
        // Entirely before the axis: nothing, not a one-point sliver.
        #expect(a.width(from: date(15, 0), to: date(16, 0)) == 0)
        // Straddling the end.
        #expect(a.width(from: a.end.addingTimeInterval(-600), to: a.end.addingTimeInterval(3600))
                == CGFloat(10 * 8))
    }

    @Test("a short server guide window shortens the axis instead of leaving empty canvas")
    func guideEndClamps() {
        let start = date(17, 0)
        let a = axis(now: start, guideEnd: start.addingTimeInterval(12 * 3600))
        #expect(a.end == start.addingTimeInterval(12 * 3600))
        #expect(a.totalWidth == CGFloat(12 * 60 * 8))
    }

    @Test("a guide window beyond the span does not stretch the axis")
    func guideEndBeyondSpanIgnored() {
        let start = date(17, 0)
        let a = axis(now: start, guideEnd: start.addingTimeInterval(96 * 3600))
        #expect(a.end == start.addingTimeInterval(48 * 3600))
    }

    /// The ruler lays its chips out at `slotWidth` while the grid draws gridlines from `slots`, and
    /// their offsets are copied straight across. That only holds if the axis spans a whole number
    /// of slots, which is what the guide-end ceiling is for.
    @Test("a guide window mid-slot is rounded up so the axis stays a whole number of slots")
    func guideEndCeilsToSlot() {
        let start = date(17, 0)
        let a = axis(now: start, guideEnd: date(23, 12))
        #expect(a.end == date(23, 30))
        #expect(a.totalWidth == CGFloat(a.slots.count) * a.slotWidth)
    }

    @Test("slots are half-hourly and cover the whole axis")
    func slots() {
        let a = axis(now: date(17, 0))
        #expect(a.slots.count == 96)
        #expect(a.slots.first == date(17, 0))
        #expect(a.slots[1] == date(17, 30))
        #expect(a.slotWidth == CGFloat(30 * 8))
        #expect(a.totalWidth == CGFloat(a.slots.count) * a.slotWidth)
    }

    @Test("prime time resolves to today when it is still ahead, tomorrow when it is not")
    func primeTime() {
        let evening = axis(now: date(17, 0))
        #expect(evening.primeTime(days: 0, from: date(17, 0), calendar: calendar) == date(20, 15))
        // Past 20:15 there is no today target left, only tomorrow's.
        let lateNight = axis(now: date(22, 0))
        #expect(lateNight.primeTime(days: 0, from: date(22, 0), calendar: calendar) == nil)
        #expect(lateNight.primeTime(days: 1, from: date(22, 0), calendar: calendar)
                == date(20, 15, day: 5))
    }

    /// Reported from the Apple TV: the evening chips jumped about a day instead of to prime time.
    @Test("prime time lands on 20:15 of the intended day, not a day later")
    func primeTimeLandsOnTheIntendedDay() {
        let morning = date(9, 23)
        let a = axis(now: morning)
        #expect(a.primeTime(days: 0, from: morning, calendar: calendar) == date(20, 15))
        #expect(a.primeTime(days: 1, from: morning, calendar: calendar) == date(20, 15, day: 5))
    }

    /// After 20:15 today's target is gone, and tomorrow's must still be tomorrow's, not the day
    /// after. A forward-searching date lookup rolls both by a day here.
    @Test("after prime time, today's chip hides and tomorrow's stays tomorrow")
    func primeTimeAfterTheEvening() {
        let late = date(21, 0)
        let a = axis(now: late)
        #expect(a.primeTime(days: 0, from: late, calendar: calendar) == nil)
        #expect(a.primeTime(days: 1, from: late, calendar: calendar) == date(20, 15, day: 5))
    }

    @Test("prime time outside a clamped axis is nil so the chip can hide instead of dead-ending")
    func primeTimeOutsideClampedAxis() {
        let start = date(17, 0)
        let short = axis(now: start, guideEnd: start.addingTimeInterval(2 * 3600))
        #expect(short.primeTime(days: 0, from: start, calendar: calendar) == nil)
    }

    @Test("contains covers the axis half-open, start inclusive and end exclusive")
    func containsBounds() {
        let a = axis(now: date(17, 0))
        #expect(a.contains(a.start))
        #expect(a.contains(a.end.addingTimeInterval(-1)))
        #expect(!a.contains(a.end))
        #expect(!a.contains(a.start.addingTimeInterval(-1)))
    }
}
