import Testing
import UIKit
import SwiftUI
@testable import Sodalite

/// Sodalite#109 follow-up, reported on the shipped fix: the controls view had no air above the
/// artwork or below the progress bar, and dropping into the ambient view was a visible jump.
///
/// Both come out of one number. The tvOS Now Playing column carries the cover, the title block, the
/// transport row and the scrubber inside the 960pt title-safe band, and the old sizes added up to
/// 967pt with a one-line album title and 1033 with a wrapped one. There was no whitespace because
/// there was no room, and SwiftUI bought the missing room by taking the album title's second line
/// away. The travel is the same number seen from the other side: when the chrome leaves, the column
/// recentres by half of what left.
///
/// So this pins the budget rather than any single control's size. The font metrics are read at
/// runtime, since they are what the layout actually gets.
@MainActor
struct NowPlayingVerticalBudgetTests {

    private func lineHeight(_ style: UIFont.TextStyle) -> CGFloat {
        UIFont.preferredFont(forTextStyle: style).lineHeight
    }

    /// Transport row over scrubber track over time labels.
    private var chrome: CGFloat {
        NowPlayingMetrics.transportPrimary
            + NowPlayingMetrics.chromeSpacing
            + NowPlayingMetrics.scrubTrackHeight
            + NowPlayingMetrics.scrubLabelSpacing
            + lineHeight(.caption1)
    }

    /// The real block, hosted at the width the centred column gives it.
    ///
    /// Measured rather than added up: both of its wrapping lines are strings rather than constants,
    /// and a SwiftUI text block runs about 1pt per line over `UIFont.lineHeight`, which an arithmetic
    /// budget silently spends (Sodalite#110 round 3).
    static func metadata(_ sample: MetadataSample) -> CGFloat {
        let view = NowPlayingMetadata(context: sample.context,
                                      title: sample.title,
                                      artist: sample.artist,
                                      centered: true)
        return UIHostingController(rootView: view.frame(width: NowPlayingMetrics.soloColumnWidth))
            .sizeThatFits(in: CGSize(width: NowPlayingMetrics.soloColumnWidth,
                                     height: .greatestFiniteMagnitude)).height
    }

    /// One line each, which is what a song off an album looks like.
    static let plain = MetadataSample(context: "Rumours",
                                      title: "Go Your Own Way",
                                      artist: "Fleetwood Mac")

    /// The case the round-3 report is about: a podcast whose show name wraps and whose episode title
    /// wraps under it. Both lines at their limit at once, which is the most the block may ever be.
    static let worst = MetadataSample(
        context: "Conversations with Tyler: Economics, Culture and Everything Else",
        title: "560. The Fall of the Aztecs: Cortes and Montezuma (Part 3)",
        artist: "Goalhanger Podcasts")

    /// A one-line show name over an episode title that needs two. The round-3 report in one string:
    /// the old ramp allowed this title exactly one line and ellipsised the rest of it.
    static let podcast = MetadataSample(context: "The Rest Is History",
                                        title: "560. The Fall of the Aztecs: Cortes and Montezuma (Part 3)",
                                        artist: "Goalhanger Podcasts")

    /// The same podcast with a title that cannot wrap, so the only difference between the two is the
    /// line under test.
    static let podcastShortTitle = MetadataSample(context: "The Rest Is History",
                                                 title: "Aztecs",
                                                 artist: "Goalhanger Podcasts")

    private func metadata(_ sample: MetadataSample) -> CGFloat { Self.metadata(sample) }

    /// Beside the queue the title block lives in the OTHER column, so this one is cover over chrome.
    private var wideCoverColumn: CGFloat {
        NowPlayingMetrics.coverSide(compact: false)
            + NowPlayingMetrics.columnSpacing
            + chrome
    }

    /// The same album once the chrome and the queue have gone: the title block has moved in here,
    /// and nothing is reserved behind the chrome because the title already filled the gap.
    private func ambientColumn(_ sample: MetadataSample) -> CGFloat {
        NowPlayingMetrics.coverSide(compact: false)
            + NowPlayingMetrics.columnSpacing
            + metadata(sample)
    }

    /// A SINGLE-track album, the only case with no queue column to give the title block up to. The
    /// chrome leaves and nothing arrives, so half its height stays reserved.
    private func soloColumn(_ sample: MetadataSample, chromeShown: Bool) -> CGFloat {
        NowPlayingMetrics.coverSide(compact: false)
            + NowPlayingMetrics.columnSpacing
            + metadata(sample)
            + NowPlayingMetrics.columnSpacing
            + (chromeShown ? chrome : chrome / 2)
    }

    private func margin(_ columnHeight: CGFloat) -> CGFloat {
        (NowPlayingMetrics.tvSafeBandHeight - columnHeight) / 2
    }

    // MARK: - The whitespace that was reported missing

    @Test("The controls view keeps real air above the cover and under the times")
    func oneLineTitleBreathes() {
        #expect(margin(soloColumn(Self.plain, chromeShown: true)) >= 40)
    }

    /// The common case, not the edge one: of nine sample album titles six wrapped at the old 560pt
    /// column width and four still wrap at 720. A wrapped line costs a whole line of the budget, and
    /// it was that line the old budget could not pay, so the title was truncated to one instead.
    /// The most the block may ever be: both wrapping lines wrapped at once, the chrome up, and no
    /// queue to hand the block over to. 14pt a side is thin, and deliberately so, because every
    /// lighter case has far more: it is the case that must FIT, `oneLineTitleBreathes` is the one
    /// that must breathe.
    @Test("A wrapped show name over a wrapped episode title still fits the band")
    func wrappedTitleStillFits() {
        let column = soloColumn(Self.worst, chromeShown: true)

        #expect(column <= NowPlayingMetrics.tvSafeBandHeight)
        #expect(margin(column) >= 10)
    }

    /// The defect round 3 reported. Pinned as a difference between two blocks that vary in nothing
    /// but the length of that one line, so it names no font and survives a retune: clamp the title
    /// back to a single line and the two heights become equal.
    ///
    /// Not measured against `UIFont.lineHeight` on purpose. SwiftUI lays the second title3 line out
    /// at 56pt where the font table says 57.28, and a budget written from the table is wrong in
    /// whichever direction the reader did not expect.
    @Test("An episode title that needs a second line is given one")
    func episodeTitleKeepsItsSecondLine() {
        let extra = Self.metadata(Self.podcast) - Self.metadata(Self.podcastShortTitle)

        #expect(extra > 20, "a wrapping episode title has to cost a line, not an ellipsis")
    }

    @Test("The lone column is wider than the one beside the queue, which is what keeps titles unwrapped")
    func soloColumnIsTheWiderOne() {
        #expect(NowPlayingMetrics.soloColumnWidth > NowPlayingMetrics.wideColumnWidth)
    }

    // MARK: - The jump

    /// The transition the screen actually makes. The queue never leaves without the chrome and the
    /// chrome never leaves without the queue, so the old model here (solo column with chrome, then
    /// the same column without it) described a state an album with a queue never passes through, and
    /// it read 43pt while the screen was moving 97. Both columns are centred, so the travel is half
    /// the difference between them.
    @Test("The cover barely moves when the queue and the chrome leave")
    func coverTravelsLessThanAJump() {
        for sample in [Self.plain, Self.worst] {
            let travel = abs(wideCoverColumn - ambientColumn(sample)) / 2

            #expect(travel <= 50)
        }
    }

    /// A single-track album makes the other transition, and there the reserve is what keeps it small:
    /// without it the column loses the chrome's full height and the artwork drops 85pt.
    @Test("A single-track album settles rather than jumps when the chrome leaves")
    func singleTrackCoverTravelsLessThanAJump() {
        let travel = (soloColumn(Self.plain, chromeShown: true)
                      - soloColumn(Self.plain, chromeShown: false)) / 2

        #expect(travel > 0)
        #expect(travel <= 50)
    }

    // MARK: - The column beside the queue

    @Test("With the queue up, the cover column still clears the band on its own")
    func twoColumnCoverColumnFits() {
        let column = NowPlayingMetrics.coverSide(compact: false)
            + NowPlayingMetrics.columnSpacing
            + chrome

        #expect(column <= NowPlayingMetrics.tvSafeBandHeight)
    }
}

/// Metadata as the screen gets it: three strings, any of which may be a podcast's.
struct MetadataSample: Sendable {
    let context: String
    let title: String
    let artist: String
}
