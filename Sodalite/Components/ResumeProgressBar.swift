import SwiftUI

/// Resume bar across the bottom of card artwork. One component for `MediaCard` and the episode
/// rows, which held byte-identical copies of it.
struct ResumeProgressBar: View {
    /// 0...1. Callers hold Jellyfin percentages; they convert, so the view has a single unit.
    let fraction: Double
    var height: CGFloat = 10
    var cornerRadius: CGFloat = 12

    /// Opaque, and neither a material nor a translucent black. Both of those let the artwork
    /// through, so on a bright still the track ends up as light as the fill and the played part
    /// stops being readable, which is the defect this replaces. The level matches the Top Shelf
    /// renderer's track so the shelf and the app show the same bar.
    private static let trackLevel = 0.13

    var body: some View {
        GeometryReader { geo in
            VStack {
                Spacer()
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color(white: Self.trackLevel))
                        .frame(height: height)
                    Rectangle()
                        // .tint reads the WindowGroup tint and follows supporter state. Never
                        // Color.accentColor, which is the static asset (hard-coded blue).
                        .fill(.tint)
                        .frame(width: geo.size.width * min(max(fraction, 0), 1), height: height)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
