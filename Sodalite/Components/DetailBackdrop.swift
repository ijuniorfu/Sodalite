import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Shared fullscreen backdrop with gradient overlay used in all detail views.
struct DetailBackdrop: View {
    let imageURL: URL?
    /// Hero stand-in for items lacking backdrop art: portrait poster scaled to screen width, top-pinned so its useful upper half stays on screen. Replaced the flat grey plate, then the heavy ambient blur-fill (Sodalite#15).
    var posterFallbackURL: URL? = nil

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass

    /// iPhone portrait uses the portrait poster as a full-bleed hero. vSizeClass != .compact (rather
    /// than == .regular) treats the unresolved first frame as portrait. tvOS/iPad and iPhone
    /// landscape keep the landscape backdrop.
    private var isPhonePortrait: Bool {
        #if os(iOS)
        hSizeClass == .compact && vSizeClass != .compact
        #else
        false
        #endif
    }

    private var heroURL: URL? {
        // Portrait phone shows the poster ONLY, never the landscape backdrop, so a not-yet-loaded
        // poster (e.g. an episode's series stub) shows a neutral placeholder instead of flashing a
        // stretched 16:9 backdrop.
        if isPhonePortrait { return posterFallbackURL }
        return imageURL ?? posterFallbackURL
    }

    /// Blur only the landscape-fallback poster (upscaled into a wide area). A real backdrop, or the
    /// portrait poster hero, fills naturally and stays sharp.
    private var usesPosterFill: Bool {
        imageURL == nil && posterFallbackURL != nil && !isPhonePortrait
    }

    var body: some View {
        GeometryReader { geo in
            AsyncCachedImage(url: heroURL) { image in
                if usesPosterFill {
                    // Poster-as-hero: `.fill` scales to screen width, top-aligned to keep the useful upper half on screen. radius-8 blur (was 32 ambient, Sodalite#15) only smooths upscaling artefacts. drawingGroup bounds the blur to one Metal layer; an unbounded offscreen blur buffer broke detail-overlay sibling compositing on tvOS (glass panel + buttons vanished, nothing focusable, Back escaped the app).
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                        .clipped()
                        .blur(radius: 8)
                        .drawingGroup()
                } else {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } placeholder: {
                Rectangle().fill(Color.Theme.surface)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            // Light uniform dim for hero-text readability.
            .overlay(Color.black.opacity(0.15))
        }
    }
}

/// Scrollable content overlay fading transparent-to-opaque over the backdrop.
///
/// `hero` slot (title-card logo) floats on the artwork above the gradient, not the black panel, so dark logos stay legible (black on ultraThinMaterial would vanish). Empty default keeps no-hero overlays (collection, catalog) unchanged.
/// `primary` slot (glass panel + button row) makes the first screen one viewport tall with hero + panel + buttons bottom-aligned, maximizing visible backdrop (Sodalite#15 round 6). Empty default keeps the fixed 500 pt hero window for non-split overlays (collection, catalog, person).
struct DetailContentOverlay<Hero: View, Primary: View, Content: View>: View {
    @ViewBuilder let hero: () -> Hero
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let content: () -> Content

    /// Scroll-driven full-screen dim: 0 at top, ramps to 0.3 one hero-window deep, restoring readability over bright artwork without losing the full-bleed look.
    @State private var scrollDim: Double = 0

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    /// Shorter clear hero window on a phone so content is reachable with one swipe.
    private var heroWindow: CGFloat { hSizeClass == .compact ? 320 : 500 }

    /// iPhone-only horizontal content inset for the Dynamic Island. The detail view stays full-bleed
    /// (backdrop + scrims keep covering the screen, so fades and the viewport-tall first block are
    /// untouched); only the content rows + hero are padded by the real window safe-area inset, which is
    /// ~0 in portrait and ~59 in landscape (the island eats the leading edge). iPad/tvOS get nothing.
    private var contentSafeInset: CGFloat {
        #if os(iOS)
        guard hSizeClass == .compact || vSizeClass == .compact else { return 0 }
        let insets = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets
        return max(insets?.left ?? 0, insets?.right ?? 0)
        #else
        return 0
        #endif
    }

    /// Denser content scrim in iPhone landscape (vSizeClass == .compact): the busy landscape backdrop
    /// shows through the default 0.55 behind the bare action-button row, reading as a bright strip
    /// between the metadata bubble and the overview box. Portrait / iPad / tvOS keep 0.55.
    private var scrimOpacity: Double { vSizeClass == .compact ? 0.78 : 0.55 }

    init(
        @ViewBuilder hero: @escaping () -> Hero = { EmptyView() },
        @ViewBuilder primary: @escaping () -> Primary,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.hero = hero
        self.primary = primary
        self.content = content
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if Primary.self == EmptyView.self {
                    Color.clear.frame(height: heroWindow)
                    gradientWithHero
                } else {
                    // First page one viewport tall, hero + primary bottom-aligned; the Spacer hands leftover space to the backdrop so the button row ends flush with the fold.
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer(minLength: 0)
                        gradientWithHero
                        VStack(alignment: .leading, spacing: 0) {
                            primary()
                        }
                        // Inset content out of the Dynamic Island; the scrim (below) stays full-width.
                        .padding(.horizontal, contentSafeInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 24 pt, matching the panel-to-buttons gap.
                        .padding(.bottom, 24)
                        .background(Color.black.opacity(scrimOpacity))
                    }
                    .containerRelativeFrame(.vertical)
                }

                VStack(alignment: .leading, spacing: 40) {
                    content()
                }
                // Inset content out of the Dynamic Island; the scrim (below) stays full-width.
                .padding(.horizontal, contentSafeInset)
                // Bound to the viewport, leading-aligned, so a wide child can't stretch the column
                // past the screen and shove the whole content block off-center (section titles were
                // being clipped on the left). Matches the primary slot's constraint.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 80)
                .background(Color.black.opacity(scrimOpacity))

                // Trailing filler so a short content block doesn't end in a hard gradient edge; same scrim, sized past any 4K tvOS safe-area inset.
                Color.black.opacity(scrimOpacity).frame(minHeight: 600)
            }
        }
        .background(Color.black.opacity(scrollDim).ignoresSafeArea())
        .onScrollGeometryChange(for: Double.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            // Linear ramp over the clear hero window, capped at 0.3.
            scrollDim = min(max(offset / heroWindow, 0), 1) * 0.3
        }
    }

    // Hero rides as a gradient overlay (not a stacked layer) to keep the sibling structure the focus engine scrolls; drawn on top so the logo stays visible. Full-bleed redesign (Sodalite#15): backdrop stays behind a scrim, text containers carry their own material.
    private var gradientWithHero: some View {
        LinearGradient(
            // End matches the panel scrim (scrimOpacity) so there is no hard step where the fade meets
            // the panel; 0.64 keeps the mid-stop proportional (0.35/0.55) so portrait is unchanged.
            colors: [.clear, .black.opacity(scrimOpacity * 0.64), .black.opacity(scrimOpacity)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 200)
        .overlay(alignment: .bottomLeading) {
            hero()
                .padding(.horizontal, metrics.rowInset)
                .padding(.horizontal, contentSafeInset)
                .padding(.bottom, 8)
        }
    }
}

/// Legacy shape for overlays without a `primary` slot (collection, catalog, person): fixed 500 pt hero window.
extension DetailContentOverlay where Primary == EmptyView {
    init(
        @ViewBuilder hero: @escaping () -> Hero = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(hero: hero, primary: { EmptyView() }, content: content)
    }
}
