import SwiftUI

/// Recordings + scheduled timers, the "Aufnahmen" side of the Live TV
/// tab's segment toggle. Recordings are plain JellyfinItems and launch
/// the normal VOD player.
struct RecordingsView: View {
    @Environment(\.dependencies) private var dependencies
    let model: RecordingsViewModel
    let tint: Color

    @State private var playerItem: JellyfinItem?
    @State private var isPlayerPresented = false
    @State private var recordingToDelete: JellyfinItem?

    private var imageService: JellyfinImageService { dependencies.jellyfinImageService }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                recordingsSection
                scheduledSection
                seriesSection
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 40)
        }
        .task { await model.load() }
        .overlay {
            if let userID = dependencies.activeUserID {
                PlayerLauncher(
                    isPresented: $isPlayerPresented,
                    item: playerItem,
                    startFromBeginning: false,
                    playbackService: dependencies.jellyfinPlaybackService,
                    userID: userID,
                    preferences: dependencies.playbackPreferences,
                    cachedPlaybackInfo: nil,
                    tintColor: tint
                )
                .allowsHitTesting(false)
            }
        }
        .alert(
            Text("livetv.recordings.deleteConfirm"),
            isPresented: Binding(
                get: { recordingToDelete != nil },
                set: { if !$0 { recordingToDelete = nil } }
            )
        ) {
            Button("livetv.recordings.delete", role: .destructive) {
                if let item = recordingToDelete {
                    Task { await model.deleteRecording(item) }
                }
                recordingToDelete = nil
            }
            Button("common.cancel", role: .cancel) { recordingToDelete = nil }
        }
        .alert(
            Text("livetv.recording.error.title"),
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Recordings

    @ViewBuilder
    private var recordingsSection: some View {
        Text("livetv.recordings.title").font(.title2).bold()
        if model.recordings.isEmpty && !model.isLoading {
            Text("livetv.recordings.empty").foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 32), count: 4),
                      alignment: .leading, spacing: 32) {
                ForEach(model.recordings) { item in
                    RecordingCard(
                        item: item,
                        imageURL: imageService.imageURL(
                            itemID: item.id, imageType: .primary,
                            tag: item.imageTags?.primary, maxWidth: 600),
                        tint: tint,
                        onPlay: {
                            playerItem = item
                            isPlayerPresented = true
                        },
                        onDelete: { recordingToDelete = item }
                    )
                }
            }
        }
    }

    // MARK: - Scheduled

    @ViewBuilder
    private var scheduledSection: some View {
        Text("livetv.recordings.scheduled").font(.title2).bold()
        if model.timers.isEmpty && !model.isLoading {
            Text("livetv.recordings.scheduledEmpty").foregroundStyle(.secondary)
        } else {
            ForEach(model.timers) { timer in
                TimerRow(
                    title: timer.name ?? "",
                    subtitle: timerSubtitle(timer),
                    isSeries: timer.seriesTimerId != nil,
                    tint: tint,
                    onCancel: { Task { await model.cancelTimer(timer) } }
                )
            }
        }
    }

    @ViewBuilder
    private var seriesSection: some View {
        if !model.seriesTimers.isEmpty {
            Text("livetv.recordings.seriesTimers").font(.title2).bold()
            ForEach(model.seriesTimers) { timer in
                TimerRow(
                    title: timer.name ?? "",
                    subtitle: timer.channelName,
                    isSeries: true,
                    tint: tint,
                    onCancel: { Task { await model.cancelSeriesTimer(timer) } }
                )
            }
        }
    }

    private func timerSubtitle(_ timer: LiveTvTimer) -> String? {
        var parts: [String] = []
        if let channel = timer.channelName { parts.append(channel) }
        if let start = timer.startDate {
            parts.append(start.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 16:9 recording card: backdrop image, title, runtime line, an
/// in-progress badge while the recording is still running. Select plays;
/// delete goes through a dedicated focusable trash chip.
private struct RecordingCard: View {
    let item: JellyfinItem
    let imageURL: URL?
    let tint: Color
    let onPlay: () -> Void
    let onDelete: () -> Void

    @FocusState private var focused: Bool
    @FocusState private var deleteFocused: Bool

    /// "92 min" style runtime; JellyfinItem has no display-ready date
    /// field (premiereDate is a raw string), so the runtime stands in.
    private var runtimeLabel: String? {
        guard let ticks = item.runTimeTicks, ticks > 0 else { return nil }
        let minutes = Int(ticks / 600_000_000)
        guard minutes > 0 else { return nil }
        return "\(minutes) min"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                AsyncImage(url: imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.white.opacity(0.08))
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(focused ? tint : .white.opacity(0.15),
                                      lineWidth: focused ? 4 : 1)
                )
                if item.status == "InProgress" {
                    Label("livetv.recordings.inProgress", systemImage: "record.circle")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                        .padding(8)
                }
            }
            .scaleEffect(focused ? 1.05 : 1.0)
            .focusable()
            .focused($focused)
            .animation(.easeInOut(duration: 0.15), value: focused)
            .stableTap(isFocused: focused) { onPlay() }

            Text(item.name).font(.headline).lineLimit(1)
            HStack {
                if let runtimeLabel {
                    Text(runtimeLabel)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(deleteFocused ? Color.black : .secondary)
                    .padding(8)
                    .background(Circle().fill(deleteFocused ? AnyShapeStyle(tint) : AnyShapeStyle(Color.clear)))
                    .focusable()
                    .focused($deleteFocused)
                    .stableTap(isFocused: deleteFocused) { onDelete() }
            }
        }
    }
}

/// Scheduled-timer row: name, channel/time line, series badge, cancel chip.
private struct TimerRow: View {
    let title: String
    let subtitle: String?
    let isSeries: Bool
    let tint: Color
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: isSeries ? "record.circle.fill" : "record.circle")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("livetv.recordings.cancelTimer")
                .font(.caption.bold())
                .foregroundStyle(focused ? Color.black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(focused ? AnyShapeStyle(tint) : AnyShapeStyle(Color.white.opacity(0.12))))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(focused ? 0.10 : 0.04)))
        .focusable()
        .focused($focused)
        .stableTap(isFocused: focused) { onCancel() }
    }
}
