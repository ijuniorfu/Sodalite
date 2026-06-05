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

/// Isolated view so we can read coordinator state directly with `@State`
/// observation without capturing `dismiss` in closures that outlive the
/// view tree.
private struct NowPlayingContent: View {
    let coordinator: MusicPlaybackCoordinator
    let dismiss: DismissAction

    @Environment(\.dependencies) private var dependencies

    /// Focus state enum for the transport row so we can set default focus
    /// on the Play/Pause button.
    @FocusState private var transportFocus: TransportButton?

    var body: some View {
        ZStack {
            // Opaque base. The fullScreenCover must never show the tab UI
            // behind it, and the blurred-art layer alone is not opaque: its
            // placeholder is nearly transparent while the image loads and
            // the 0.65 dim overlay plus the heavy blur leave the layer
            // partly see-through. A solid black base guarantees full cover.
            Color.black
                .ignoresSafeArea()

            // Blurred album art background
            backgroundArt

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // Top padding / space for backdrop bleed
                    Spacer().frame(height: 60)

                    // Main content: art + metadata + transport + progress
                    HStack(alignment: .top, spacing: 80) {
                        // Left column: cover + transport + progress
                        VStack(spacing: 32) {
                            albumCover
                            transportRow
                            progressRow
                        }
                        .frame(width: 560)

                        // Right column: track metadata + queue
                        VStack(alignment: .leading, spacing: 32) {
                            trackMetadata
                            queueList
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 80)

                    Spacer().frame(height: 80)
                }
            }
        }
        .ignoresSafeArea()
        // The Siri Remote play/pause button is delivered to the responder
        // chain as a UIPress while the app is foreground, NOT through
        // MPRemoteCommandCenter (that path only fires from Control Center /
        // background). Handle it here so the in-app remote button toggles.
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
        let item = coordinator.currentItem
        let coverURL: URL? = {
            guard let item else { return nil }
            if let albumID = item.albumId, let albumTag = item.albumPrimaryImageTag {
                return dependencies.jellyfinImageService.imageURL(
                    itemID: albumID,
                    imageType: .primary,
                    tag: albumTag,
                    maxWidth: 400
                )
            }
            return dependencies.jellyfinImageService.posterURL(for: item, maxWidth: 400)
        }()

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
        let item = coordinator.currentItem
        let coverURL: URL? = {
            guard let item else { return nil }
            if let albumID = item.albumId, let albumTag = item.albumPrimaryImageTag {
                return dependencies.jellyfinImageService.imageURL(
                    itemID: albumID,
                    imageType: .primary,
                    tag: albumTag,
                    maxWidth: 600
                )
            }
            return dependencies.jellyfinImageService.posterURL(for: item, maxWidth: 600)
        }()

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
                Text(item.name)
                    .font(.title2)
                    .fontWeight(.bold)
                    .lineLimit(2)

                if let artist = item.trackArtistLine, !artist.isEmpty {
                    Text(artist)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let albumArtist = item.albumArtist,
                   !albumArtist.isEmpty,
                   albumArtist != item.trackArtistLine {
                    Text(albumArtist)
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
        .padding(.top, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Transport row

    private var transportRow: some View {
        HStack(spacing: 28) {
            // Previous
            TransportIconButton(
                systemImage: "backward.fill",
                focusKey: TransportButton.previous,
                transportFocus: $transportFocus,
                isDisabled: !coordinator.hasPrevious
            ) {
                coordinator.previous()
            }

            // Play / Pause (default focus; set via .onAppear in body)
            TransportIconButton(
                systemImage: coordinator.isPlaying ? "pause.fill" : "play.fill",
                focusKey: TransportButton.playPause,
                transportFocus: $transportFocus,
                isLarge: true
            ) {
                coordinator.togglePlayPause()
            }

            // Next
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

    // MARK: - Progress row

    private var progressRow: some View {
        let elapsed = coordinator.currentTime
        let total = max(coordinator.duration, 1)
        let fraction = elapsed / total

        return VStack(spacing: 8) {
            // Progress bar (read-only)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(height: 5)

                    Capsule()
                        .fill(Color.white)
                        .frame(width: geo.size.width * CGFloat(min(fraction, 1.0)), height: 5)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 5)

            // Time labels
            HStack {
                Text(formatSeconds(elapsed))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer()

                Text(formatSeconds(coordinator.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
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
                            onSelect: {
                                coordinator.play(
                                    queue: coordinator.queue,
                                    startAt: index
                                )
                            }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func formatSeconds(_ seconds: Double) -> String {
        guard seconds > 0 && seconds.isFinite else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
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
        // tvOS scales .title / .title2 to huge point sizes (~76 / ~57pt),
        // so the glyph filled the whole frame and the focus circle cut
        // across it. Use fixed symbol sizes clearly smaller than the
        // circle so the tint ring sits comfortably around the icon.
        let size: CGFloat = isLarge ? 96 : 74
        let iconFont: Font = .system(size: isLarge ? 38 : 28, weight: .semibold)

        // Use the .focusable + stableTap convention, NOT a Button: a
        // tvOS Button (even with .buttonStyle(.plain)) paints the system
        // white focus card behind itself. Our focus look is the tinted
        // circle fill + tint stroke below.
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

// MARK: - QueueRow

private struct QueueRow: View {
    let track: JellyfinItem
    let isCurrent: Bool
    let onSelect: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 16) {
            // Playing indicator or track number
            if isCurrent {
                Image(systemName: "music.note")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .frame(width: 24, alignment: .center)
            } else {
                Text(track.indexNumber.map { String($0) } ?? "")
                    .font(.caption)
                    .foregroundStyle(focused ? .white : Color.secondary)
                    .monospacedDigit()
                    .frame(width: 24, alignment: .trailing)
            }

            // Track name: current track wears the tint; others follow focus.
            // Use a computed property to keep the ternary type-safe.
            QueueTrackName(
                name: track.name,
                isCurrent: isCurrent,
                focused: focused
            )

            // Duration
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

/// Separate view so we can apply `.foregroundStyle(.tint)` for the current
/// track without mixing `TintShapeStyle` and `Color` in a ternary expression.
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
