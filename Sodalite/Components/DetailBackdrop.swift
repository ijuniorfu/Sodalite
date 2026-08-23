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

    /// tvOS fold marker state. The offset feeds off the same scroll-geometry hook as scrollDim.
    @State private var scrollOffset: CGFloat = 0
    @State private var belowFoldHeight: CGFloat = 0
    @State private var hintSettled = false

    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.verticalSizeClass) private var vSizeClass
    private var metrics: LayoutMetrics { LayoutMetrics.current(hSizeClass) }
    /// Shorter clear hero window on a phone so content is reachable with one swipe.
    private var heroWindow: CGFloat { hSizeClass == .compact ? 320 : 500 }

    /// Everything past the content block is scroll the viewer can travel with nothing to see, and the
    /// filler used to be 600pt of it. On tvOS that is not just dead travel: the focus engine parks a
    /// focused row ~180pt above the bottom edge, but the LAST row can only get as far as the maximum
    /// scroll offset allows, so 680pt of trailing space (filler plus the 80pt padding) pinned a 400pt
    /// poster row 2pt below the top edge and clipped its focus scale and ring (Sodalite#52, measured
    /// in a tvOS focus probe). Keeping the trailing space near that ~180pt lands the last row where
    /// every other row lands. Shorter still on a phone, where the same filler was most of a screen.
    private var trailingFiller: CGFloat {
        hSizeClass == .compact ? 60 : 120
    }

    /// The reserved band and the hint itself are tvOS only: a scrollable page is self-evident on a
    /// touch device (Sodalite#53).
    private var reservesScrollHint: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    private var showsScrollHint: Bool {
        reservesScrollHint && ScrollHintPolicy.isVisible(
            scrollOffset: scrollOffset,
            belowFoldHeight: belowFoldHeight,
            hasSettled: hintSettled
        )
    }

    /// Per-side window safe-area insets, used to push only the CONTENT clear of the Dynamic Island while
    /// the backdrop + scrims stay full-bleed. Read from the window (the overlay is full-bleed, so the
    /// environment inset is gone). In landscape the island is on one side only, so only that side is
    /// inset and the island itself covers that margin; ~0 in portrait / iPad / tvOS (no change).
    private var safeLeading: CGFloat {
        #if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.left ?? 0
        #else
        0
        #endif
    }
    private var safeTrailing: CGFloat {
        #if os(iOS)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.right ?? 0
        #else
        0
        #endif
    }

    /// iPhone portrait is the one tier that keeps the safe area on this page (the detail views pass
    /// `ignoresSafeArea(when: !isPhonePortrait)`), so the scrolling scrim stopped 34pt above the
    /// screen edge while the backdrop behind it ran to the edge: a hard bright band under the home
    /// indicator on every detail page (measured on an iPhone 17 Pro and reproduced in a simulator
    /// probe, brightness 61 to 134 at exactly 34pt). The scroll view now bleeds past that edge and
    /// the primary block pays the inset back, so the first page stands where it stood.
    private var isPhonePortrait: Bool {
        #if os(iOS)
        hSizeClass == .compact && vSizeClass != .compact
        #else
        false
        #endif
    }
    private var bottomBleed: CGFloat {
        #if os(iOS)
        guard isPhonePortrait else { return 0 }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first?.keyWindow?.safeAreaInsets.bottom ?? 0
        #else
        return 0
        #endif
    }

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
                        // Inset the content past the island; the scrim (.frame + .background below)
                        // stays full-width, so no gray strip / backdrop margin appears.
                        .padding(.leading, safeLeading)
                        .padding(.trailing, safeTrailing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 24 pt matching the panel-to-buttons gap, widened on tvOS to a constant
                        // band that holds the fold marker (Sodalite#53).
                        .padding(.bottom, ScrollHintPolicy.primaryBottomInset(reservesHint: reservesScrollHint) + bottomBleed)
                        .overlay(alignment: .bottom) {
                            if reservesScrollHint {
                                ScrollHintChevron(isVisible: showsScrollHint)
                                    .padding(.bottom, 10)
                            }
                        }
                        .background(Color.black.opacity(0.55))
                    }
                    // iPhone landscape: do NOT force the first page to viewport height. In the short
                    // landscape viewport the content overflows, the panel scrim bleeds past the fold and
                    // overlaps the content-block scrim -> a doubled-up dark strip under the buttons that
                    // scrolls with the content. Sizing the block to its content keeps the scrims contiguous.
                    .modifier(FirstPageViewportHeight(active: vSizeClass != .compact))
                }

                VStack(alignment: .leading, spacing: 40) {
                    content()
                }
                // Height of the real below-fold content. The trailing filler below makes every page
                // technically scrollable, so the hint keys off this instead (Sodalite#53).
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    belowFoldHeight = height
                }
                // Inset the content past the island; the scrim stays full-width (no strip / margin).
                .padding(.leading, safeLeading)
                .padding(.trailing, safeTrailing)
                // Bound to the viewport, leading-aligned, so a wide child can't stretch the column
                // past the screen and shove the whole content block off-center (section titles were
                // being clipped on the left). Matches the primary slot's constraint.
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 80)
                .background(Color.black.opacity(0.55))

                // Trailing filler so a short content block doesn't end in a hard gradient edge; same scrim, sized past any 4K tvOS safe-area inset.
                Color.black.opacity(0.55)
                    .frame(minHeight: trailingFiller)
                    .overlay(alignment: .bottom) {
                        // Rubber-band overscroll pulls the content clear of the bottom edge and would
                        // uncover the bare backdrop there. This band hangs below the content end and
                        // scrolls with it, so it is off screen at rest and covers exactly the gap the
                        // bounce opens. An overlay on purpose: it carries no layout weight, so it adds
                        // no scroll travel of its own. Reading the overscroll from scroll geometry and
                        // sizing a fixed band instead does not work, the state update never reaches the
                        // overlay while the drag is in flight (measured, height stayed 0).
                        Color.black.opacity(0.55)
                            .frame(height: 600)
                            .offset(y: 600)
                            .allowsHitTesting(false)
                    }
            }
        }
        .ignoresSafeArea(when: isPhonePortrait, edges: .bottom)
        .background(Color.black.opacity(scrollDim).ignoresSafeArea())
        .onScrollGeometryChange(for: Double.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            // Linear ramp over the clear hero window, capped at 0.3.
            scrollDim = min(max(offset / heroWindow, 0), 1) * 0.3
            scrollOffset = offset
        }
        // Hold the hint back through the cover's present transition, so a viewer who immediately
        // presses down never sees it appear.
        .task {
            try? await Task.sleep(for: .milliseconds(800))
            hintSettled = true
        }
    }

    // Hero rides as a gradient overlay (not a stacked layer) to keep the sibling structure the focus engine scrolls; drawn on top so the logo stays visible. Full-bleed redesign (Sodalite#15): backdrop stays behind a scrim, text containers carry their own material.
    private var gradientWithHero: some View {
        LinearGradient(
            colors: [.clear, .black.opacity(0.35), .black.opacity(0.55)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 200)
        .overlay(alignment: .bottomLeading) {
            hero()
                .padding(.horizontal, metrics.rowInset)
                .padding(.leading, safeLeading)
                .padding(.trailing, safeTrailing)
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

/// Applies `.containerRelativeFrame(.vertical)` only when active (everywhere except iPhone landscape),
/// so the viewport-tall first page is kept where there's room and dropped where it would overflow.
/// File-scoped (not nested in DetailContentOverlay) to avoid colliding with that type's `Content` param.
private struct FirstPageViewportHeight: ViewModifier {
    let active: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.containerRelativeFrame(.vertical)
        } else {
            content
        }
    }
}

/// Hands the detail page's vertical scroll proxy back to the view, iOS only.
///
/// The proxy has to be captured outside DetailContentOverlay to reach the glass panel; the reader
/// inside the content block only covers what sits below it. On tvOS this is a pass-through: the
/// focus engine already scrolls, and wrapping the overlay there would put a container into the tree
/// the focus picker walks for no gain.
struct PageScrollProxyCapture: ViewModifier {
    @Binding var proxy: ScrollViewProxy?

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        ScrollViewReader { pageProxy in
            content
                .onAppear { proxy = pageProxy }
        }
        #endif
    }
}
