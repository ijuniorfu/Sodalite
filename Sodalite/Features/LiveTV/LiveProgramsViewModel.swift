import SwiftUI
import Observation

/// Backs the Live TV "Übersicht" tab: fetches recommended programs per
/// category and synthesizes the channel a tapped program needs for playback.
/// Timer / favorite state is intentionally NOT held here — the Übersicht view
/// reuses the shared `EPGGuideViewModel` for those so the optimistic overlay
/// stays consistent across all three Live TV segments.
@Observable
@MainActor
final class LiveProgramsViewModel {
    /// Programs per category. Categories with an empty array are not rendered.
    private(set) var rows: [LiveProgramCategory: [JellyfinProgram]] = [:]
    private(set) var isLoading = false
    private(set) var loadError: String?

    /// Per-row item cap, matches jellyfin-web's recommended view.
    private static let limit = 20

    private let service: JellyfinLiveTvServiceProtocol
    private let userID: String

    init(service: JellyfinLiveTvServiceProtocol, userID: String) {
        self.service = service
        self.userID = userID
    }

    /// Fan out one recommended-programs call per category concurrently.
    /// Idempotent: a second call while data exists is a no-op.
    func load() async {
        guard rows.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        await withTaskGroup(of: (LiveProgramCategory, [JellyfinProgram]?).self) { group in
            for category in LiveProgramCategory.allCases {
                group.addTask { [service, userID] in
                    let programs = try? await service.getRecommendedPrograms(
                        userID: userID, category: category, limit: Self.limit)
                    return (category, programs)
                }
            }
            var collected: [LiveProgramCategory: [JellyfinProgram]] = [:]
            var anySucceeded = false
            for await (category, programs) in group {
                if let programs {
                    anySucceeded = true
                    if !programs.isEmpty { collected[category] = programs }
                }
            }
            rows = collected
            // Only surface an error when every category failed; a partial
            // failure still renders the rows that loaded.
            loadError = anySucceeded ? nil : String(
                localized: "livetv.loadFailed.title", defaultValue: "Couldn't load programs")
        }
    }

    /// Build the `JellyfinChannel` a tapped program needs for the popover /
    /// playback. Prefers the guide's real channel object (logo tag, favorite
    /// state) when it is already loaded; otherwise synthesizes a minimal one
    /// from the program's channel id + name, decoupled from the guide's
    /// 50-at-a-time channel pagination.
    func channel(for program: JellyfinProgram, guideChannels: [JellyfinChannel]) -> JellyfinChannel? {
        guard let channelID = program.channelId else { return nil }
        if let real = guideChannels.first(where: { $0.id == channelID }) {
            return real
        }
        return JellyfinChannel(
            id: channelID,
            name: program.channelName ?? program.name,
            channelNumber: nil,
            imageTags: nil,
            currentProgram: nil,
            userData: nil
        )
    }
}
