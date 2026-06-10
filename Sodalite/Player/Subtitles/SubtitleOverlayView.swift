import SwiftUI
import Combine
import AetherEngine
import SwiftAssRenderer

/// Renders the subtitle cues active at the current playback time on top
/// of the video. Two body kinds:
///
/// - **Text**, a centered, semi-transparent black box with white text.
///   At most one text cue is active at a time in practice (FFmpeg's
///   text decoders merge same-time rects into one cue), but the layout
///   tolerates more.
/// - **Image**, a bitmap with normalised position (PGS / DVB / HDMV).
///   Multiple bitmap cues can overlap (signs/songs at the top while
///   dialogue stays at the bottom), so we render every active one.
///
/// When a styled ASS renderer is active (`assRenderer` non-nil), the
/// whole cue pipeline above is bypassed: swift-ass-renderer's
/// `AssSubtitlesView` draws the frame itself with the track's authored
/// fonts, colors and positioning, so none of the user styling /
/// offset preferences apply (authored positioning is absolute).
struct SubtitleOverlayView: View {
    let cues: [SubtitleCue]
    let currentTime: Double
    /// User-selected text size, applied as a multiplier on top of the
    /// base `.title3` font. Picked up from PlaybackPreferences.
    let fontSize: PlaybackPreferences.SubtitleFontSize
    /// User-selected foreground colour for text cues. Bitmap cues
    /// (PGS / DVB) ignore this, the colour is baked into the
    /// graphic by the source.
    let textColor: PlaybackPreferences.SubtitleColor
    /// Background style for text cues (box / outline / none).
    let background: PlaybackPreferences.SubtitleBackground
    /// Subtitle timing offset in seconds. Positive = subs appear later
    /// than the audio they translate; negative = subs appear earlier.
    /// Applied to both text and image cues so the user's setting works
    /// regardless of which decoder produced the cue.
    let delaySeconds: Double
    /// User-selected vertical position. `default` preserves the
    /// historical text baseline (height − 100) and the source-baked
    /// position of bitmap cues. The other cases anchor the text
    /// baseline to a fraction of the overlay rect height (measured
    /// from the bottom edge) and shift bitmap cues by the delta
    /// between that anchor and their source position, so the same
    /// dial works across both decoders.
    let verticalPosition: PlaybackPreferences.SubtitleVerticalPosition
    /// User-selected subtitle font. `system` uses tvOS SF Pro;
    /// `highLegibility` uses bundled Atkinson Hyperlegible. Only
    /// affects text cues, bitmap cues are pre-rendered by the source
    /// decoder and ignore this.
    let font: PlaybackPreferences.SubtitleFont
    /// User-selected subtitle weight. `.regular` is the default and
    /// reads at tvOS UI weight, `.bold` brings back the heavier
    /// rendering some users prefer for contrast against busy
    /// backgrounds. Applied to both font choices.
    let weight: PlaybackPreferences.SubtitleWeight
    /// True while the transport bar / player chrome is visible. When
    /// set, text cues snap to a fixed clearance above the UI so the
    /// transport bar never occludes dialogue. The user's chosen
    /// vertical position is intentionally overridden while the UI is
    /// up so positions above the bar don't end up wastefully high and
    /// positions below the bar don't end up hidden. Bitmap cues keep
    /// their source-baked layout (signs / songs at the top of frame
    /// would never be occluded anyway).
    let controlsVisible: Bool
    /// Styled ASS renderer, non-nil exactly while an embedded ASS/SSA
    /// track is active AND swift-ass-renderer initialized. When set,
    /// the package's view replaces the cue rendering below entirely.
    let assRenderer: AssSubtitlesRenderer?
    /// Reload pre-announcements from the ASS coordinator (see
    /// `ASSFrameHostView`'s nil suppression).
    let assReloadSignal: PassthroughSubject<Void, Never>
    /// Codec of the active subtitle stream, lowercased ("ass" / "ssa" /
    /// "subrip" / ...). Drives the raw-event-line stripper for the
    /// fallback case where an ASS track is active but the styled
    /// renderer bailed (missing header, setup failure).
    let activeSubtitleCodec: String?

    /// Fixed bottom inset for text cues while the transport bar is
    /// visible. Sits above the transport-bar gradient band (300 pt
    /// from the bottom edge) with a small breathing margin.
    private static let controlsVisibleBottomInset: CGFloat = 280

    var body: some View {
        if let assRenderer {
            // Styled ASS path. AssSubtitlesView sizes its canvas and
            // draws rendered frames itself; we only pin it over the
            // same full-bleed rect the cue overlay uses. No user
            // styling / offset / position preferences here, the track
            // author's layout is absolute.
            ASSRenderedSubtitles(
                renderer: assRenderer,
                reloadSignal: assReloadSignal,
                currentOffset: currentTime
            )
            .allowsHitTesting(false)
        } else {
            cueOverlay
        }
    }

    private var cueOverlay: some View {
        GeometryReader { geo in
            // `Color.clear` fills the proposed size so the overlay
            // covers the same rect as the underlying video layer
            // (otherwise SwiftUI may collapse the ZStack to the
            // largest child's frame and the .offset math suddenly
            // anchors against a small box). `.overlay(alignment:
            // .topLeading)` makes (0, 0) of the inner views the
            // top-left corner of that rect, so subtitle absolute
            // positions become a straight `.offset(x: pixels, y:
            // pixels)` from there.
            Color.clear
                .overlay(alignment: .topLeading) {
                    ForEach(activeCues, id: \.id) { cue in
                        switch cue.body {
                        case .text(let text):
                            let display = isASSTrackActive ? strippedASSText(text) : text
                            if !display.isEmpty {
                                textOverlay(display, in: geo.size, safeAreaInsets: geo.safeAreaInsets)
                            }
                        case .image(let image):
                            imageOverlay(image, in: geo.size)
                        }
                    }
                }
        }
        .allowsHitTesting(false)
    }

    /// True while the selected stream is ASS/SSA. Only reachable in the
    /// cue path when the styled renderer is nil (coordinator bailed),
    /// in which case cue text bodies are still RAW event lines
    /// (`ReadOrder,Layer,...,Text`) and must be stripped before display.
    private var isASSTrackActive: Bool {
        activeSubtitleCodec == "ass" || activeSubtitleCodec == "ssa"
    }

    /// Fallback when the styled renderer is unavailable: raw event lines
    /// must never reach the screen. Mirrors the engine's cleanASSBody.
    private func strippedASSText(_ raw: String) -> String {
        var lines: [String] = []
        for line in raw.split(separator: "\n") {
            // ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text
            // Require an integer ReadOrder in the first field so clean
            // sidecar text with 8+ commas isn't falsely treated as a
            // raw event line and truncated.
            let fields = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9, Int(fields[0]) != nil else { lines.append(String(line)); continue }
            var text = String(fields[8])
            text = text.replacingOccurrences(of: "\\N", with: "\n")
            text = text.replacingOccurrences(of: "\\n", with: "\n")
            text = text.replacingOccurrences(of: "\\h", with: " ")
            text = text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Text branch

    private func textOverlay(_ text: String, in size: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        // Anchored to the bottom-centre of the video rect: the text
        // block's bottom edge sits the chosen distance above the actual
        // screen bottom, and the block grows upward as it wraps to more
        // lines. Center-anchoring (the old `.position` approach) clipped
        // 3-line cues at large font when "Bottom Edge" put the center at
        // 99 % of height, because half the block extended past the
        // screen. Width is capped so long lines wrap with horizontal
        // margins on either side.
        let maxWidth = max(0, size.width - 240)
        // tvOS .title3 lands around 24-29pt depending on platform
        // metrics; the user-selected scale multiplies that for
        // small/medium/large/xlarge.
        let basePoints: CGFloat = 28
        let pointSize = basePoints * fontSize.scale
        let placement = textBottomPlacement(in: size, safeAreaInsets: safeAreaInsets)
        return styledText(text, pointSize: pointSize)
            .frame(maxWidth: maxWidth)
            .padding(.bottom, placement.padding)
            .frame(width: size.width, height: size.height, alignment: .bottom)
            .offset(y: placement.offsetBelowSafeArea)
            .transition(.opacity)
    }

    /// Distance from the actual screen bottom to the bottom of the
    /// text block, expressed as a `(padding, offsetBelowSafeArea)`
    /// pair. The overlay's `size` is safe-area-reduced (tvOS insets
    /// ~60 pt vertically), so positions close to the screen bottom
    /// have to bleed past the safe area into the letterbox bar via
    /// `.offset(y:)`; positions further up are inside the safe area
    /// and use ordinary bottom padding.
    ///
    /// Default keeps the historical ~80 pt gap above the safe area
    /// bottom so existing users see no shift. Fraction-based cases
    /// ("Bottom Edge", "Low", etc.) are interpreted relative to the
    /// *full screen* height so "Bottom Edge" (1 %) actually lands ~10 pt
    /// above the screen bottom (inside the letterbox for letterboxed
    /// content). Earlier code used `size.height * fraction`, which
    /// effectively meant "1 % above the safe area bottom" ≈ 70 pt
    /// above the screen bottom, well above the letterbox bar.
    private func textBottomPlacement(in size: CGSize, safeAreaInsets: EdgeInsets) -> (padding: CGFloat, offsetBelowSafeArea: CGFloat) {
        if controlsVisible {
            return (Self.controlsVisibleBottomInset, 0)
        }
        if let fraction = verticalPosition.fractionFromBottom {
            let fullScreenHeight = size.height + safeAreaInsets.top + safeAreaInsets.bottom
            let desiredAboveScreenBottom = fullScreenHeight * CGFloat(fraction)
            let safeBottom = safeAreaInsets.bottom
            if desiredAboveScreenBottom >= safeBottom {
                return (desiredAboveScreenBottom - safeBottom, 0)
            }
            return (0, safeBottom - desiredAboveScreenBottom)
        }
        return (80, 0)
    }

    /// Compose the text view itself, font + colour + the chosen
    /// background style (box / outline / none). Outline is drawn by
    /// stacking eight nudged copies in black behind the foreground
    /// text; the system has no per-character stroke modifier on tvOS.
    @ViewBuilder
    private func styledText(_ text: String, pointSize: CGFloat) -> some View {
        let foreground = foregroundColor
        let baseFont = subtitleBaseFont(pointSize: pointSize)

        switch background {
        case .box:
            Text(text)
                .font(baseFont)
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        case .outline:
            ZStack {
                ForEach(outlineOffsets, id: \.self) { offset in
                    Text(text)
                        .font(baseFont)
                        .foregroundStyle(.black)
                        .multilineTextAlignment(.center)
                        .offset(x: offset.x, y: offset.y)
                }
                Text(text)
                    .font(baseFont)
                    .foregroundStyle(foreground)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        case .shadow:
            Text(text)
                .font(baseFont)
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 1)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
        case .none:
            // Truly plain text. Legibility depends entirely on contrast
            // between glyph colour and the underlying frame, picked by
            // users who would rather lose a sub line than tint a single
            // pixel of the picture.
            Text(text)
                .font(baseFont)
                .foregroundStyle(foreground)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
        }
    }

    private var foregroundColor: Color {
        switch textColor {
        case .white: return .white
        case .yellow: return Color(red: 1.0, green: 0.86, blue: 0.0)
        case .gray: return Color(white: 0.85)
        }
    }

    /// Pick the base font for the active subtitle-font and -weight
    /// preferences. SF Pro uses `.regular` / `.semibold`; Atkinson
    /// Hyperlegible uses its bundled Regular / Bold PostScript faces
    /// (matching `UIAppFonts` registration). The heavier cut on SF
    /// Pro is `.semibold` rather than `.bold` because true `.bold`
    /// reads as caption-pasted-on rather than caption-burned-in at
    /// player point sizes.
    private func subtitleBaseFont(pointSize: CGFloat) -> Font {
        switch font {
        case .system:
            let systemWeight: Font.Weight = (weight == .bold) ? .semibold : .regular
            return Font.system(size: pointSize, weight: systemWeight)
        case .highLegibility:
            let postScriptName = (weight == .bold)
                ? "AtkinsonHyperlegible-Bold"
                : "AtkinsonHyperlegible-Regular"
            return Font.custom(postScriptName, size: pointSize)
        }
    }

    /// Eight-direction offsets for the outline-style background. Two
    /// pixels at TV viewing distance reads as a solid edge without
    /// looking like a dropshadow.
    private static let outlineOffsets: [CGPoint] = [
        CGPoint(x: -2, y: -2), CGPoint(x: 0, y: -2), CGPoint(x: 2, y: -2),
        CGPoint(x: -2, y:  0),                       CGPoint(x: 2, y:  0),
        CGPoint(x: -2, y:  2), CGPoint(x: 0, y:  2), CGPoint(x: 2, y:  2),
    ]
    private var outlineOffsets: [CGPoint] { Self.outlineOffsets }

    // MARK: - Image branch

    private func imageOverlay(_ image: SubtitleImage, in size: CGSize) -> some View {
        // Normalised position is in source-video coordinates. The
        // outer Color.clear fills the GeometryReader rect, the
        // overlay's alignment is .topLeading, so an .offset of
        // (x_pixels, y_pixels) from the top-left puts the image's
        // top-left corner at exactly (x_pixels, y_pixels) on the
        // video.
        let frameW = image.position.width * size.width
        let frameH = image.position.height * size.height
        let originX = image.position.minX * size.width
        let originY = image.position.minY * size.height + bitmapVerticalShift(in: size, cueHeight: frameH)

        return Image(decorative: image.cgImage, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.high)
            .frame(width: frameW, height: frameH)
            .offset(x: originX, y: originY)
    }

    /// Vertical shift applied to a bitmap cue's source-baked Y so the
    /// active vertical-position step also moves PGS / DVB / DVD
    /// renderings. `default` returns 0 so source layouts are preserved
    /// exactly (signs at the top, dialogue at the bottom, karaoke
    /// wherever the disc placed it).
    ///
    /// Non-default cases apply a uniform shift of `-fraction * height`,
    /// which lifts a bottom-aligned source cue so its bottom edge
    /// lands at the same Y the text branch picks for that step. Cues
    /// that the source placed near the top of frame get dragged up by
    /// the same delta, which can clip on the steeper steps; users
    /// picking a non-default position have opted into the override.
    private func bitmapVerticalShift(in size: CGSize, cueHeight: CGFloat) -> CGFloat {
        guard let fraction = verticalPosition.fractionFromBottom else { return 0 }
        return -CGFloat(fraction) * size.height
    }

    // MARK: - Active-cue lookup

    /// Returns every cue whose time range contains `currentTime`.
    /// Cues are sorted by `startTime` (engine + sidecar both insert in
    /// order), so we binary-search for the first cue starting after
    /// now and walk back collecting any whose endTime hasn't passed.
    private var activeCues: [SubtitleCue] {
        guard !cues.isEmpty else { return [] }
        // Apply user's delay offset. delay > 0 means subs should
        // appear LATER than they would by default, so the cue at
        // [10..12] is "perceived" as [11..13] for delay = +1.
        // Equivalently, look up at (currentTime - delay), at audio
        // time 11.0 we want the cue whose intrinsic start was 10.0.
        let lookupTime = currentTime - delaySeconds
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].startTime > lookupTime {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        var result: [SubtitleCue] = []
        var i = lo - 1
        while i >= 0, cues[i].startTime <= lookupTime {
            if cues[i].endTime >= lookupTime {
                result.append(cues[i])
            }
            i -= 1
        }
        return result.reversed()
    }
}

// MARK: - Styled ASS host

/// Hosts the styled ASS frame stream. Functionally a clone of
/// swift-ass-renderer's `AssSubtitlesView` (canvas sized in
/// layoutSubviews, frames drawn into an image view at
/// `ProcessedImage.imageRect`), with ONE behavioral difference: nil
/// frames caused by the coordinator's `reloadTrack` are suppressed.
/// The renderer frees the track and publishes a transient nil before
/// the identical re-render lands; the upstream view hides immediately
/// on nil, which made every visible subtitle blink at each batched
/// reload. The coordinator pre-announces each reload via
/// `reloadSignal`, so suppression is deterministic: after a signal,
/// nil frames keep the last image until the next rendered frame
/// arrives (or a safety timeout elapses, covering the corner where a
/// reload coincides with a genuine cue end and the re-render's nil is
/// swallowed by the publisher's duplicate filter). A plain nil with
/// no announced reload is a real cue end and hides instantly.
private struct ASSRenderedSubtitles: UIViewRepresentable {
    let renderer: AssSubtitlesRenderer
    let reloadSignal: PassthroughSubject<Void, Never>
    /// Current playback offset (the overlay's `currentTime`, which is
    /// the clock's sourceTime mirror). The frame view needs it for its
    /// track-data queries; the renderer's own offset is not public.
    let currentOffset: Double

    func makeUIView(context: Context) -> ASSFrameHostView {
        ASSFrameHostView(renderer: renderer, reloadSignal: reloadSignal)
    }

    func updateUIView(_ view: ASSFrameHostView, context: Context) {
        view.currentOffset = currentOffset
    }
}

final class ASSFrameHostView: UIView {
    /// Playback offset fed by the representable on every SwiftUI
    /// update (10 Hz via the overlay's currentTime input).
    var currentOffset: Double = 0
    private let renderer: AssSubtitlesRenderer
    private let canvasScale: CGFloat
    private let imageView = UIImageView()
    private var lastRenderBounds = CGRect.zero
    private var cancellables = Set<AnyCancellable>()
    /// Suppress nil frames until this deadline (armed by each reload
    /// signal). `.distantPast` = no suppression.
    private var suppressNilDeadline = Date.distantPast
    /// Deferred hide scheduled while suppression is active, so a
    /// swallowed real cue end still hides at the deadline.
    private var hideWorkItem: DispatchWorkItem?
    /// Upper bound for one reload round-trip (parse + first-use font
    /// matching + render). Generous; typical is tens of ms.
    private static let reloadSuppressWindow: TimeInterval = 0.5

    init(renderer: AssSubtitlesRenderer, reloadSignal: PassthroughSubject<Void, Never>) {
        self.renderer = renderer
        self.canvasScale = UITraitCollection.current.displayScale
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        addSubview(imageView)
        // No receive(on:): the coordinator sends on the main actor
        // right BEFORE calling reloadTrack, and synchronous delivery
        // guarantees the suppression is armed before the renderer's
        // transient nil can possibly arrive.
        reloadSignal
            .sink { [weak self] in
                self?.suppressNilDeadline = Date().addingTimeInterval(Self.reloadSuppressWindow)
            }
            .store(in: &cancellables)
        renderer
            .framesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handleFrameChanged($0) }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A transient zero-bounds layout pass must never reach the
        // renderer: a 0x0 canvas renders every event as nil, which
        // hides the visible subtitle without any reload announced.
        guard !bounds.isEmpty else {
            return
        }
        // Rescale the live image to the new bounds (mirrors upstream),
        // then update the renderer canvas.
        if !lastRenderBounds.isEmpty, imageView.image != nil, lastRenderBounds != bounds {
            let ratioX = bounds.width / lastRenderBounds.width
            let ratioY = bounds.height / lastRenderBounds.height
            let f = imageView.frame
            imageView.frame = CGRect(
                x: f.origin.x * ratioX, y: f.origin.y * ratioY,
                width: f.width * ratioX, height: f.height * ratioY
            ).integral
        }
        renderer.setCanvasSize(bounds.size, scale: canvasScale)
    }

    private func handleFrameChanged(_ image: ProcessedImage?) {
        if let image {
            hideWorkItem?.cancel()
            hideWorkItem = nil
            suppressNilDeadline = .distantPast
            lastRenderBounds = bounds
            imageView.frame = image.imageRect
            imageView.image = UIImage(cgImage: image.image)
            imageView.isHidden = false
        } else {
            let remaining = suppressNilDeadline.timeIntervalSinceNow
            guard remaining > 0 else {
                // Real cue end (no reload announced): hide instantly.
                hideWorkItem?.cancel()
                hideWorkItem = nil
                hideNow()
                return
            }
            // Reload in flight: keep the last image; arm the safety
            // hide at the deadline in case no frame follows (reload
            // coinciding with a real cue end).
            guard hideWorkItem == nil else { return }
            scheduleSafetyHide(after: remaining)
        }
    }

    /// Resolve a suppression window that ended without a new frame.
    /// Re-arms itself when a newer reload extended the deadline while
    /// the work item was already queued.
    ///
    /// The renderer does NOT republish after a reload whose re-render
    /// is visually identical to what was on screen: libass change
    /// detection reports "unchanged" and the pipeline skips the
    /// publish, leaving the frame subject parked on the transient nil
    /// (device evidence: show -> reload -> suppressed nil -> no frame
    /// ever -> safety hide cutting an ACTIVE line). So at the
    /// deadline, ask the track data directly: an event active at the
    /// current offset means the on-screen image is still correct,
    /// keep it and end suppression; no active event means the reload
    /// coincided with a genuine cue end, hide.
    private func scheduleSafetyHide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWorkItem = nil
            let remaining = self.suppressNilDeadline.timeIntervalSinceNow
            if remaining > 0 {
                self.scheduleSafetyHide(after: remaining)
                return
            }
            let stillActive = !self.renderer.dialogues(at: self.currentOffset).isEmpty
            if stillActive {
                self.suppressNilDeadline = .distantPast
                // The renderer's frame subject is parked on nil now, so
                // the REAL cue end would publish nil-after-nil and the
                // pipeline's duplicate filter swallows it: this frame
                // would linger forever. Watch the track data for the
                // end ourselves until the next published frame takes
                // over.
                self.scheduleEndWatch()
            } else {
                self.hideNow()
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Poll the track data while holding a manually-kept frame; hide
    /// the moment no event is active anymore. Cancelled by any freshly
    /// published frame (handleFrameChanged cancels `hideWorkItem`).
    private func scheduleEndWatch() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWorkItem = nil
            if self.renderer.dialogues(at: self.currentOffset).isEmpty {
                self.hideNow()
            } else {
                self.scheduleEndWatch()
            }
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func hideNow() {
        imageView.isHidden = true
        imageView.image = nil
        suppressNilDeadline = .distantPast
    }
}
