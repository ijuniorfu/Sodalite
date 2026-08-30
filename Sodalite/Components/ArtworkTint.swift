import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The two ends of a page's tint: the colour directly under the hero band, and the colour the page
/// has deepened to by its bottom. Deliberately not black at the far end, the page keeps its colour
/// all the way down (Vincent, 2026-08-30).
struct ArtworkPalette: Equatable {
    var near: Color
    var far: Color

    /// Unresolved artwork. Black at both ends, so a page that has not read its image yet is simply
    /// the black the detail views already put under their ZStack, never a seam.
    static let base = ArtworkPalette(near: .black, far: .black)
}

/// Page tint derived from hero artwork, for the iPhone-portrait detail page.
///
/// The portrait hero is a 16:9 band that ends mid-screen; below it the page carries a colour pulled
/// from the artwork's own bottom edge, so the band dissolves into the page instead of ending on a
/// hard cut (Sodalite#95). The colour is clamped dark before it is handed out: a bright backdrop
/// (snow, daylight) would otherwise hand white body text a near-white canvas.
///
/// The mean is taken as it falls, with no saturation lift. Measured on a busy backdrop (One Piece,
/// 2026-08-30): its bottom edge averages to a near-grey (saturation 0.058) because its hues cancel,
/// and a chroma-weighted pass confirms there is nothing to recover, hue coherence 0.08 against 0.75
/// on a single-palette backdrop. A page painted from that noise would claim a colour the artwork
/// does not have; the neutral canvas is the honest reading.
enum ArtworkTint {

    #if canImport(UIKit)
    /// Average of the image's bottom eighth, clamped to a dark, half-saturated version of itself.
    ///
    /// The strip, not the whole image: the tint has to continue the pixels the band actually ends on,
    /// and a full-frame average of a dark-bottom/bright-top backdrop lands somewhere neither edge is.
    nonisolated static func bottomEdgePalette(of image: UIImage) -> ArtworkPalette? {
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
    /// transition rather than a black page. The far end is the same colour deepened, never black.
    nonisolated static func clamped(red: CGFloat, green: CGFloat, blue: CGFloat) -> ArtworkPalette {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        UIColor(red: red, green: green, blue: blue, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        let sat = min(saturation, 0.55)
        let near = min(max(brightness, 0.09), 0.24)
        return ArtworkPalette(
            near: Color(uiColor: UIColor(hue: hue, saturation: sat, brightness: near, alpha: 1)),
            far: Color(uiColor: UIColor(hue: hue, saturation: sat, brightness: near * 0.4, alpha: 1))
        )
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

    private var palettes: [URL: ArtworkPalette] = [:]
    private var inFlight: Set<URL> = []

    func palette(for url: URL?) -> ArtworkPalette? {
        guard let url else { return nil }
        return palettes[url]
    }

    /// Derives and stores the tint for `url` once. Cheap (one 1x1 draw of an already decoded image),
    /// but off the main actor regardless: it runs while the detail page is painting its first frame.
    func resolve(_ image: UIImage, for url: URL) {
        guard palettes[url] == nil, !inFlight.contains(url) else { return }
        inFlight.insert(url)
        Task.detached(priority: .utility) {
            let palette = ArtworkTint.bottomEdgePalette(of: image)
            await MainActor.run {
                ArtworkTintStore.shared.inFlight.remove(url)
                if let palette {
                    ArtworkTintStore.shared.palettes[url] = palette
                }
            }
        }
    }
}
#endif
