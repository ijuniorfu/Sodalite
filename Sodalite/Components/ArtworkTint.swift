import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Page tint derived from hero artwork, for the iPhone-portrait detail page.
///
/// The portrait hero is a 16:9 band that ends mid-screen; below it the page carries a colour pulled
/// from the artwork's own bottom edge, so the band dissolves into the page instead of ending on a
/// hard cut (Sodalite#95). The colour is clamped dark before it is handed out: a bright backdrop
/// (snow, daylight) would otherwise hand white body text a near-white canvas.
enum ArtworkTint {

    /// Where a fully unresolved page sits, and the far end of every tint gradient. Matches the black
    /// each detail view puts under its ZStack, so an unresolved tint is invisible rather than a seam.
    static let base = Color.black

    #if canImport(UIKit)
    /// Average of the image's bottom eighth, clamped to a dark, half-saturated version of itself.
    ///
    /// The strip, not the whole image: the tint has to continue the pixels the band actually ends on,
    /// and a full-frame average of a dark-bottom/bright-top backdrop lands somewhere neither edge is.
    nonisolated static func bottomEdgeTint(of image: UIImage) -> Color? {
        guard let source = image.cgImage, source.width > 0, source.height > 0 else { return nil }

        // CGImage crop coordinates are top-left origin, so the bottom strip starts at height - strip.
        let stripHeight = max(1, source.height / 8)
        let strip = CGRect(
            x: 0,
            y: source.height - stripHeight,
            width: source.width,
            height: stripHeight
        )
        guard let cropped = source.cropping(to: strip) else { return nil }

        // Averaging by drawing into a single pixel: CoreGraphics box-filters the whole strip down for
        // us, so there is no per-pixel loop to get wrong and no second decode of the image.
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        return clamped(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255
        )
    }

    /// Dark enough for white text at any artwork brightness, saturated enough to still read as the
    /// artwork's colour, and lifted off pure black so a dark backdrop still produces a visible
    /// transition rather than a black page.
    nonisolated static func clamped(red: CGFloat, green: CGFloat, blue: CGFloat) -> Color {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        UIColor(red: red, green: green, blue: blue, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return Color(uiColor: UIColor(
            hue: hue,
            saturation: min(saturation, 0.55),
            brightness: min(max(brightness, 0.09), 0.24),
            alpha: 1
        ))
    }
    #endif
}

#if canImport(UIKit)
/// Tints already derived, keyed by the artwork URL that produced them.
///
/// Two sibling views need the same colour (the band fades into it, the page below is painted with
/// it) and only one of them ever sees the decoded image, so the tint travels through here rather
/// than through a binding threaded across every detail screen. Keyed by URL, so a second page
/// opened over the first cannot inherit its colour.
@MainActor
@Observable
final class ArtworkTintStore {
    static let shared = ArtworkTintStore()

    private var tints: [URL: Color] = [:]
    private var inFlight: Set<URL> = []

    func tint(for url: URL?) -> Color? {
        guard let url else { return nil }
        return tints[url]
    }

    /// Derives and stores the tint for `url` once. Cheap (one 1x1 draw of an already decoded image),
    /// but off the main actor regardless: it runs while the detail page is painting its first frame.
    func resolve(_ image: UIImage, for url: URL) {
        guard tints[url] == nil, !inFlight.contains(url) else { return }
        inFlight.insert(url)
        Task.detached(priority: .utility) {
            let tint = ArtworkTint.bottomEdgeTint(of: image)
            await MainActor.run {
                ArtworkTintStore.shared.inFlight.remove(url)
                if let tint {
                    ArtworkTintStore.shared.tints[url] = tint
                }
            }
        }
    }
}
#endif
