import SwiftUI

// MARK: - NowPlayingView

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dependencies) private var dependencies

    var body: some View {
        let coordinator = dependencies.musicPlaybackCoordinator
        NowPlayingContent(coordinator: coordinator, dismiss: dismiss)
    }
}

// MARK: - NowPlayingContent

/// Isolated view to read coordinator state via `@State` without capturing `dismiss` in closures that
/// outlive the view tree.
private struct NowPlayingContent: View {
    let coordinator: MusicPlaybackCoordinator
    let dismiss: DismissAction

    @Environment(\.dependencies) private var dependencies

    /// Transport-row focus, so default focus lands on Play/Pause.
    @FocusState private var transportFocus: TransportButton?

    var body: some View {
        ZStack {
            // Opaque base: the cover must never show the tab UI, and the blurred-art layer isn't
            // opaque (transparent placeholder while loading; the 0.65 dim + heavy blur stay
            // see-through). Solid black guarantees full cover.
            Color.black
                .ignoresSafeArea()

            backgroundArt

            HStack(alignment: .center, spacing: 80) {
                VStack(spacing: 32) {
                    albumCover
                    transportRow
                    progressRow
                }
                .frame(width: 560)

                VStack(alignment: .leading, spacing: 28) {
                    trackMetadata
                    ScrollView(.vertical, showsIndicators: false) {
                        queueList
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 60)
        }
        .ignoresSafeArea()
        // Foreground, the Siri Remote play/pause arrives as a UIPress on the responder chain, NOT via
        // MPRemoteCommandCenter (that fires only from Control Center / background). Handle it here.
        .onPlayPauseCommand {
            LogTap.shared.note("[NowPlaying] onPlayPauseCommand (in-app remote button)")
            coordinator.togglePlayPause()
        }
        // Auto-dismiss when playback stops (queue cleared / video handoff)
        .onChange(of: coordinator.currentItem == nil) { _, stopped in
            if stopped { dismiss() }
        }
        .onAppear {
            transportFocus = .playPause
        }
    }

    // MARK: - Background art

    private var backgroundArt: some View {
        let coverURL = coordinator.currentItem.flatMap {
            dependencies.jellyfinImageService.musicCoverURL(for: $0, maxWidth: 400)
        }

        return AsyncCachedImage(url: coverURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle()
                .fill(Color.white.opacity(0.04))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .blur(radius: 80)
        .overlay(Color.black.opacity(0.65))
        .ignoresSafeArea()
    }

    // MARK: - Album cover

    private var albumCover: some View {
        let coverURL = coordinator.currentItem.flatMap {
            dependencies.jellyfinImageService.musicCoverURL(for: $0, maxWidth: 600)
        }

        return AsyncCachedImage(url: coverURL) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 72))
                        .foregroundStyle(.tertiary)
                )
        }
        .frame(width: 520, height: 520)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.55), radius: 40, y: 16)
    }

    // MARK: - Track metadata

    private var trackMetadata: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let item = coordinator.currentItem {
                if let context = coordinator.contextTitle, !context.isEmpty {
                    Text(context)
                        .font(.title2)
                        .fontWeight(.bold)
                        .lineLimit(2)

                    Text(item.name)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(item.name)
                        .font(.title2)
                        .fontWeight(.bold)
                        .lineLimit(2)
                }

                if let artist = item.trackArtistLine, !artist.isEmpty {
                    Text(artist)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            } else {
                Text(String(localized: "nowplaying.notplaying", defaultValue: "Nothing Playing"))
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Transport row

    private var transportRow: some View {
        HStack(spacing: 28) {
            TransportIconButton(
                systemImage: "backward.fill",
                focusKey: TransportButton.previous,
                transportFocus: $transportFocus,
                isDisabled: !coordinator.hasPrevious
            ) {
                coordinator.previous()
            }

            // Default focus, set via .onAppear in body.
            TransportIconButton(
                systemImage: coordinator.isPlaying ? "pause.fill" : "play.fill",
                focusKey: TransportButton.playPause,
                transportFocus: $transportFocus,
                isLarge: true
            ) {
                coordinator.togglePlayPause()
            }

            TransportIconButton(
                systemImage: "forward.fill",
                focusKey: TransportButton.next,
                transportFocus: $transportFocus,
                isDisabled: !coordinator.hasNext
            ) {
                coordinator.next()
            }
        }
    }

    // MARK: - Progress row / scrubber

    private var progressRow: some View {
        ScrubBar(coordinator: coordinator)
    }

    // MARK: - Queue list

    private var queueList: some View {
        VStack(alignment: .leading, spacing: 16) {
            if coordinator.queue.count > 1 {
                Text(String(localized: "nowplaying.queue.title", defaultValue: "Queue"))
                    .font(.headline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    ForEach(Array(coordinator.queue.enumerated()), id: \.element.id) { index, track in
                        QueueRow(
                            track: track,
                            isCurrent: index == coordinator.currentIndex,
                            isPlaying: coordinator.isPlaying,
                            onSelect: {
                                // Switch within the same queue, keeping the album/playlist context.
                                coordinator.skip(toQueueIndex: index)
                            }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Transport button focus enum

private enum TransportButton: Hashable {
    case previous
    case playPause
    case next
}

// MARK: - TransportIconButton

private struct TransportIconButton: View {
    let systemImage: String
    let focusKey: TransportButton
    @FocusState.Binding var transportFocus: TransportButton?
    var isLarge: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    private var isFocused: Bool { transportFocus == focusKey }

    var body: some View {
        // tvOS scales .title/.title2 to ~76/~57pt, so the glyph filled the frame and the focus circle
        // cut across it; fixed sizes clearly smaller than the circle keep the tint ring around the icon.
        let size: CGFloat = isLarge ? 96 : 74
        let iconFont: Font = .system(size: isLarge ? 38 : 28, weight: .semibold)

        // .focusable + stableTap, NOT a Button: a tvOS Button (even .plain) paints the system white
        // focus card; our focus look is the tinted circle fill + stroke below.
        Image(systemName: systemImage)
            .font(iconFont)
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(Color.white.opacity(
                        isFocused
                            ? (isLarge ? 0.25 : 0.18)
                            : (isLarge ? 0.12 : 0.07)
                    ))
            )
            .overlay(
                Circle()
                    .strokeBorder(.tint, lineWidth: 3)
                    .opacity(isFocused ? 1 : 0)
            )
            .scaleEffect(isFocused ? 1.1 : 1.0)
            .shadow(
                color: .black.opacity(isFocused ? 0.3 : 0),
                radius: 10,
                y: 4
            )
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .focusable(!isDisabled)
            .focused($transportFocus, equals: focusKey)
            .stableTap(isFocused: isFocused) {
                action()
            }
            .opacity(isDisabled ? 0.35 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isDisabled)
    }
}

// MARK: - ScrubBar

/// The fullscreen player's progress bar; drawn here from coordinator scrub state, with a focusable
/// UIKit overlay (`MusicScrubberInput`) owning gestures so it matches the video player.
private struct ScrubBar: View {
    let coordinator: MusicPlaybackCoordinator

    @State private var isFocused = false

    private var fraction: CGFloat { CGFloat(coordinator.displayProgress) }
    private var scrubbing: Bool { coordinator.isScrubbing }
    private var barHeight: CGFloat { scrubbing ? 10 : (isFocused ? 7 : 5) }

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(height: barHeight)

                    Capsule()
                        .fill(scrubbing ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white))
                        .frame(width: geo.size.width * fraction, height: barHeight)

                    if isFocused || scrubbing {
                        let knob: CGFloat = scrubbing ? 24 : 16
                        Circle()
                            .fill(scrubbing ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.white))
                            .frame(width: knob, height: knob)
                            .offset(x: geo.size.width * fraction - knob / 2)
                            .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 26)

            HStack {
                Text(MusicTimeFormatter.string(coordinator.displayTime))
                    .font(.caption)
                    .foregroundStyle(scrubbing ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.secondary))
                    .monospacedDigit()

                Spacer()

                Text(MusicTimeFormatter.string(coordinator.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .overlay(
            MusicScrubberInput(coordinator: coordinator, isFocused: $isFocused)
        )
        .scaleEffect(isFocused ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .animation(.easeInOut(duration: 0.2), value: scrubbing)
    }
}

// MARK: - QueueRow

private struct QueueRow: View {
    let track: JellyfinItem
    let isCurrent: Bool
    let isPlaying: Bool
    let onSelect: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 16) {
            if isCurrent {
                NowPlayingWaveIcon(isPlaying: isPlaying, font: .caption)
                    .frame(width: 24, alignment: .center)
            } else {
                Text(track.indexNumber.map { String($0) } ?? "")
                    .font(.caption)
                    .foregroundStyle(focused ? .white : Color.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: 24, alignment: .trailing)
            }

            QueueTrackName(
                name: track.name,
                isCurrent: isCurrent,
                focused: focused
            )

            if let ticks = track.runTimeTicks,
               let formatted = ResumeTimeFormatter.format(ticks: ticks) {
                Text(formatted)
                    .font(.caption)
                    .foregroundStyle(focused ? Color.white.opacity(0.85) : Color.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isCurrent
                      ? Color.white.opacity(focused ? 0.18 : 0.1)
                      : Color.white.opacity(focused ? 0.14 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.tint, lineWidth: 2)
                .opacity(focused ? 1 : 0)
        )
        .scaleEffect(focused ? 1.015 : 1.0)
        .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 10, y: 4)
        .focusable(true)
        .focused($focused)
        .animation(.easeInOut(duration: 0.15), value: focused)
        .stableTap(isFocused: focused) {
            onSelect()
        }
    }
}

// MARK: - QueueTrackName

/// Separate view to apply `.tint` for the current track without mixing TintShapeStyle and Color in a ternary.
private struct QueueTrackName: View {
    let name: String
    let isCurrent: Bool
    let focused: Bool

    var body: some View {
        Text(name)
            .font(.callout)
            .fontWeight(isCurrent ? .semibold : .regular)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(QueueTrackNameStyle(isCurrent: isCurrent, focused: focused))
    }
}

private struct QueueTrackNameStyle: ViewModifier {
    let isCurrent: Bool
    let focused: Bool

    func body(content: Content) -> some View {
        if isCurrent {
            content.foregroundStyle(.tint)
        } else {
            content.foregroundStyle(focused ? Color.white : Color.primary)
        }
    }
}
