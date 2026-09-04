import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Burns a resume bar into the cell artwork, because `TVTopShelfSectionedItem.playbackProgress`
/// is drawn by the system in white-on-white with no way to tint it, which disappears on bright
/// backdrops. Everything here is synchronous and CoreGraphics-only: no UIKit (the extension has
/// no window scene) and no suspension points while a CGImage is alive.
enum ResumeBarRenderer {

    /// Fractions of the rendered image's height, so the bar keeps its weight after the system
    /// scales the artwork down to cell width. A fixed pixel height would shrink with it, which
    /// is exactly why Jellyfin's own server-side bar reads as a hairline on Apple TV.
    private enum Metrics {
        static let barHeight = 0.031
        static let minBarHeight = 4.0
        /// Inset on the three sides the capsule touches, as a fraction of the image WIDTH so it
        /// stays even on all three (the cell is 16:9, so the same fraction of height would be a
        /// wider gap below than beside). 0.0275 of a 16:9 cell is what the app's `checkInset` comes
        /// to on its landscape card, so the shelf and the app wear the same margin (Sodalite#99).
        static let inset = 0.0275
        static let scrimHeight = 0.16
        static let scrimOpacity = 0.65
        static let jpegQuality = 0.9
    }

    /// `maxPixelSize` caps the decode: the shelf cell is far narrower than the 1280px artwork the
    /// app requests, and decoding full size would put ~3.7MB per cell through an extension with a
    /// hard memory ceiling. ImageIO downsamples during decode, so the full bitmap never exists.
    static func render(source: Data,
                       fraction: Double,
                       accent: UInt32,
                       maxPixelSize: Int) -> Data? {
        guard let image = decode(source, maxPixelSize: maxPixelSize) else { return nil }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: bounds)
        drawBar(in: context, bounds: bounds, fraction: fraction, accent: accent)

        guard let composited = context.makeImage() else { return nil }
        return encodeJPEG(composited)
    }

    // MARK: - Drawing

    /// CoreGraphics' origin is bottom-left, so the bar sits one inset above y = 0 and the scrim
    /// grows upward from the edge. Reading this as top-down is the classic way to end up with a bar
    /// in the sky.
    ///
    /// The shelf keeps its scrim where the in-app card dropped one: the system draws `cell.title`
    /// into this artwork's lower edge, and the capsule has to stay legible under it.
    private static func drawBar(in context: CGContext,
                                bounds: CGRect,
                                fraction: Double,
                                accent: UInt32) {
        let barHeight = max(Metrics.minBarHeight, bounds.height * Metrics.barHeight).rounded()
        let scrimHeight = (bounds.height * Metrics.scrimHeight).rounded()

        context.saveGState()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [CGColor(red: 0, green: 0, blue: 0, alpha: Metrics.scrimOpacity),
                                              CGColor(red: 0, green: 0, blue: 0, alpha: 0)] as CFArray,
                                     locations: [0, 1]) {
            context.clip(to: CGRect(x: 0, y: 0, width: bounds.width, height: scrimHeight))
            context.drawLinearGradient(gradient,
                                       start: CGPoint(x: 0, y: 0),
                                       end: CGPoint(x: 0, y: scrimHeight),
                                       options: [])
        }
        context.restoreGState()

        let inset = (bounds.width * Metrics.inset).rounded()
        let track = CGRect(x: inset, y: inset, width: bounds.width - 2 * inset, height: barHeight)
        context.setFillColor(CGColor(red: NeutralLevel.resumeTrack,
                                     green: NeutralLevel.resumeTrack,
                                     blue: NeutralLevel.resumeTrack,
                                     alpha: 1))
        fillCapsule(in: context, rect: track)

        let clamped = min(max(fraction, 0), 1)
        let fillWidth = (track.width * clamped).rounded()
        guard fillWidth > 0 else { return }
        context.setFillColor(color(from: accent))
        fillCapsule(in: context, rect: CGRect(x: track.minX, y: track.minY,
                                              width: fillWidth, height: barHeight))
    }

    /// Rounded caps rather than the flush rectangle this used to draw. CoreGraphics clamps a corner
    /// radius wider than half the rect, so a fill of a few percent comes out as a dot instead of a
    /// malformed shape.
    private static func fillCapsule(in context: CGContext, rect: CGRect) {
        let radius = rect.height / 2
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    private static func color(from hex: UInt32) -> CGColor {
        CGColor(red: Double((hex >> 16) & 0xff) / 255,
                green: Double((hex >> 8) & 0xff) / 255,
                blue: Double(hex & 0xff) / 255,
                alpha: 1)
    }

    // MARK: - Codec

    private static func decode(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output,
                                                                 UTType.jpeg.identifier as CFString,
                                                                 1,
                                                                 nil)
        else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: Metrics.jpegQuality]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
