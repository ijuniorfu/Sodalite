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

    /// 1080 pt less the 60 pt title-safe inset at the top and the bottom. The panel is a page of its own
    /// (`.plain`), so no card padding comes off it.
    private static let available: CGFloat = 960

    private static func hostedHeight(_ view: some View, width: CGFloat) -> CGFloat {
        UIHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            .height
    }

    /// The longest address this can ever produce, so it is the only one worth measuring: the server
    /// hands out IPv4 only (`AF_INET`), so the host is at most `255.255.255.255`, the kernel's ephemeral
    /// range tops out at 65535, and the token is a fixed 16. 45 characters, and nothing can exceed it.
    private static let longestAddress = "http://255.255.255.255:65535/2947dc41cd468014"

    private static let content = LogExportPanelContent(
        url: URL(string: longestAddress)!,
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
            The export panel needs \(total) pt plus \(spare) pt of translation headroom, and the page \
            leaves \(Self.available). Content \(contentHeight), button \(buttonHeight). Over the band \
            the hint silently becomes one truncated line.
            """
        )
    }

    /// The address is the fallback for a camera that will not focus on a television, so it has to stay
    /// one line, and at ONE size: `minimumScaleFactor` shrinks a label by exactly the fraction that makes
    /// it fit, so a panel sized to the floor rather than to the text would render 48 pt on a 10.x network
    /// and 43.6 pt on a 192.168.x one. Which address the router handed out is not a thing the type size
    /// may depend on. So the promise is scale 1, not "somewhere above the floor".
    @Test("the longest address the server can produce needs no shrinking at all")
    func longestAddressNeedsNoScaling() {
        let font = UIFont.monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .title3).pointSize,
            weight: .regular
        )
        let width = (Self.longestAddress as NSString).size(withAttributes: [.font: font]).width
        let available = LogExportPanelContent.width - 2 * LogExportPanelContent.padding

        #expect(
            width <= available,
            "the longest address is \(width) pt in \(available) pt, so it would render smaller than a short one"
        )
    }
}
#endif
