#if os(tvOS)
import Testing
import SwiftUI
import UIKit
@testable import Sodalite

/// Sodalite#148, first device round: the hint came back as one truncated line and the address lost its
/// tail. Neither was a text problem. The column added up to about 891 pt in a band that holds 840, and
/// SwiftUI pays a vertical overrun with a text line, which puts the symptom nowhere near the cause.
///
/// So the sizes are pinned here, measured rather than added: each piece is hosted and asked how tall it
/// really is, because the rendered line height differs from `UIFont.lineHeight` and the direction of the
/// difference depends on the style.
@MainActor
struct LogExportPanelBudgetTests {

    /// 1080 pt less the 60 pt title-safe inset at the top and the bottom.
    private static let titleSafeBand: CGFloat = 960
    /// `MenuPanelCover`'s `.card` style pads 60 pt above and below whatever it presents.
    private static let coverPadding: CGFloat = 120
    private static var available: CGFloat { titleSafeBand - coverPadding }

    private static func hostedHeight(_ view: some View, width: CGFloat) -> CGFloat {
        UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            .height
    }

    /// A private range plus a port is the longest address this can produce, so it is the one to measure.
    private static let content = LogExportPanelContent(
        url: URL(string: "http://192.168.178.123:49336/2947dc41cd468014")!,
        expiresAt: Date().addingTimeInterval(300)
    )

    private static let doneButton = LogActionButton(
        titleKey: "common.done",
        systemImage: "xmark",
        isEnabled: true,
        action: {}
    )

    @Test("the panel fits the title-safe band, with a line to spare for a longer translation")
    func panelFitsTheBand() {
        let inner = LogExportPanelContent.width - 2 * LogExportPanelContent.padding
        let contentHeight = Self.hostedHeight(Self.content, width: inner)
        let buttonHeight = Self.hostedHeight(Self.doneButton, width: inner)
        let total = contentHeight
            + LogExportPanelContent.blockSpacing
            + buttonHeight
            + 2 * LogExportPanelContent.padding

        // One caption line of headroom, because the hint is translated into 26 languages and the
        // measurement above only sees the one this test ran in.
        let spare = UIFont.preferredFont(forTextStyle: .caption1).lineHeight

        #expect(
            total + spare <= Self.available,
            """
            The export panel needs \(total) pt plus \(spare) pt of translation headroom, and the cover \
            leaves \(Self.available). Content \(contentHeight), button \(buttonHeight). Over the band \
            the hint silently becomes one truncated line.
            """
        )
    }

    /// The address is the fallback for a camera that will not focus on a television, so it has to stay
    /// one line. `minimumScaleFactor` only shrinks a label as far as it must, so the question is whether
    /// the floor is low enough for the longest address, not whether it is set at all.
    @Test("the longest address still fits one line above the floor")
    func addressFitsOnOneLine() {
        let longest = "http://192.168.178.123:49336/2947dc41cd468014"
        let font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .title3).pointSize,
            weight: .regular
        )
        let width = (longest as NSString).size(withAttributes: [.font: font]).width
        let available = LogExportPanelContent.width - 2 * LogExportPanelContent.padding
        let neededScale = available / width

        #expect(
            neededScale >= 0.5,
            "the longest address needs a scale of \(neededScale) in \(available) pt, below the 0.5 floor"
        )
    }
}
#endif
