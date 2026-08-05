import SwiftUI

/// What the focused program is, without opening anything. The strip holds the last program focused
/// in the grid, so moving focus to the ruler or the controls does not blank it.
struct GuideHeroView: View {
    let program: JellyfinProgram?
    let channel: JellyfinChannel?
    let metrics: GuideMetrics
    let tint: Color

    @Environment(\.dependencies) private var dependencies

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            artwork
            if let program {
                details(for: program)
            } else if let channel {
                // A channel with no EPG data still has an identity; a blank hero reads as a bug.
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text("livetv.noProgramInfo")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("livetv.guide.hero.empty")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 12)
        .frame(height: metrics.heroHeight, alignment: .top)
    }

    private var artwork: some View {
        AsyncCachedImage(
            url: programImageURL,
            fallbackURL: channelLogoURL
        ) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Rectangle().fill(Color.Theme.surface)
                Image(systemName: "tv")
                    .font(.system(size: metrics.heroThumbSize.height * 0.3))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: metrics.heroThumbSize.width, height: metrics.heroThumbSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func details(for program: JellyfinProgram) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(program.name)
                .font(.title3)
                .fontWeight(.semibold)
                .lineLimit(1)

            if let subtitle = subtitleLine(for: program) {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if program.isAiring(at: Date()) {
                GuideHeroProgressBar(program: program, tint: tint)
            }

            if let overview = program.overview, !overview.isEmpty {
                Text(overview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
        }
    }

    /// Episode identity, channel, time window and genre on one line. Anything missing drops out
    /// rather than leaving an empty separator behind.
    private func subtitleLine(for program: JellyfinProgram) -> String? {
        var parts: [String] = []
        if let episode = episodeLabel(for: program) { parts.append(episode) }
        if let name = channel?.name ?? program.channelName { parts.append(name) }
        if let start = program.startDate, let end = program.endDate {
            let formatter = DateFormatter.guideShortTime
            parts.append("\(formatter.string(from: start)) - \(formatter.string(from: end))")
        }
        if let first = program.genres?.first { parts.append(first) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Same cascade as `ProgramInfoPopover.episodeLabel`: episode title, then series name, then bare
    /// season and episode numbers, dropping anything that just repeats the title.
    private func episodeLabel(for program: JellyfinProgram) -> String? {
        let numbers: String? = if let season = program.parentIndexNumber,
                                  let episode = program.indexNumber {
            "S\(season):E\(episode)"
        } else {
            nil
        }
        if let title = program.episodeTitle, title != program.name {
            return numbers.map { "\($0) · \(title)" } ?? title
        }
        if let series = program.seriesName, series != program.name {
            return numbers.map { "\(series) · \($0)" } ?? series
        }
        return numbers
    }

    private var programImageURL: URL? {
        guard let program, !program.isSynthesized else { return nil }
        return dependencies.jellyfinImageService.imageURL(
            itemID: program.id, imageType: .primary,
            tag: program.primaryImageTag,
            maxWidth: Int(metrics.heroThumbSize.width * 2))
    }

    private var channelLogoURL: URL? {
        guard let channel else { return nil }
        return dependencies.jellyfinImageService.imageURL(
            itemID: channel.id, imageType: .primary,
            tag: channel.primaryImageTag,
            maxWidth: Int(metrics.heroThumbSize.width * 2))
    }
}

/// Progress and remaining minutes for an airing program. Its own view with its own clock, so the
/// minute tick invalidates this bar and nothing above it.
private struct GuideHeroProgressBar: View {
    let program: JellyfinProgram
    let tint: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let fraction = progress(at: context.date)
            HStack(spacing: 10) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16))
                        Capsule().fill(tint).frame(width: geometry.size.width * fraction)
                    }
                }
                .frame(width: 160, height: 5)

                if let remaining = remainingMinutes(at: context.date) {
                    Text("livetv.guide.hero.remaining \(remaining)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 14)
            .padding(.top, 2)
        }
        .frame(height: 16)
    }

    private func progress(at now: Date) -> CGFloat {
        guard let start = program.startDate, let end = program.endDate else { return 0 }
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return CGFloat(min(1, max(0, now.timeIntervalSince(start) / total)))
    }

    private func remainingMinutes(at now: Date) -> Int? {
        guard let end = program.endDate, end > now else { return nil }
        return max(1, Int(end.timeIntervalSince(now) / 60))
    }
}

extension DateFormatter {
    /// Shared short-time formatter for the guide's SwiftUI chrome.
    static let guideShortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
