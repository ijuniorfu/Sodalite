import Foundation

/// Feature #4: in-player subtitle search/download via Jellyfin
/// RemoteSearch (server needs the OpenSubtitles plugin). Downloaded
/// subtitles are attached server-side as external streams, then applied
/// live through the existing sidecar subtitle path.
@MainActor
extension PlayerViewModel {

    /// Curated language options for the in-overlay switcher. Reuses the
    /// settings language list (3-letter codes), dropping the "Auto" (nil)
    /// entry which has no concrete code to search.
    var subtitleSearchLanguageOptions: [PlaybackPreferences.LanguageChoice] {
        PlaybackPreferences.subtitleLanguageChoices.filter { $0.code != nil }
    }

    /// Opens the overlay and kicks off the first search. Seeds the
    /// language from the preferred subtitle language, else the device
    /// language, else English.
    func presentSubtitleSearch() {
        let seed = preferences.preferredSubtitleLanguage
            ?? Locale.current.language.languageCode?.identifier(.alpha3)
            ?? "eng"
        subtitleSearchLanguage = seed
        subtitleSearchVisible = true
        Task { await searchSubtitles() }
    }

    func dismissSubtitleSearch() {
        subtitleSearchVisible = false
        subtitleSearchState = .idle
    }

    /// Switches the search language and re-runs the search.
    func setSubtitleSearchLanguage(_ code: String) {
        guard code != subtitleSearchLanguage else { return }
        subtitleSearchLanguage = code
        Task { await searchSubtitles() }
    }

    /// Runs a RemoteSearch for the current language and fills state.
    func searchSubtitles() async {
        subtitleSearchState = .loading
        do {
            let results = try await playbackService.searchRemoteSubtitles(
                itemID: item.id,
                language: subtitleSearchLanguage
            )
            subtitleSearchState = results.isEmpty ? .empty : .results(results)
        } catch {
            subtitleSearchState = .error(
                String(localized: "player.subtitle.search.error",
                       defaultValue: "Subtitle search failed. The server may not have a subtitle provider installed.")
            )
        }
    }

    /// Downloads `info` server-side, refetches the active media source's
    /// streams to find the newly attached external subtitle, lists it,
    /// applies it live, and dismisses the overlay.
    func downloadAndApplySubtitle(_ info: RemoteSubtitleInfo) async {
        subtitleSearchState = .downloading(id: info.id)
        do {
            let before = Set(subtitleStreams.map(\.index))
            try await playbackService.downloadRemoteSubtitle(itemID: item.id, subtitleID: info.id)

            // The server attaches the subtitle asynchronously; poll
            // PlaybackInfo a few times until the new external stream
            // surfaces on the active media source.
            var newStream: MediaStream?
            for attempt in 0..<5 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(600)) }
                let response = try await playbackService.getPlaybackInfo(
                    itemID: item.id, userID: userID, profile: nil
                )
                guard let source = response.mediaSources.first(where: { $0.id == mediaSourceID })
                    ?? response.mediaSources.first else { continue }
                let refreshed = Self.dedupedSubtitleStreams(from: source.mediaStreams)
                if let added = refreshed.first(where: {
                    $0.isExternal == true && !before.contains($0.index)
                }) {
                    subtitleStreams = refreshed
                    newStream = added
                    break
                }
            }

            guard let applied = newStream else {
                subtitleSearchState = .error(
                    String(localized: "player.subtitle.search.error",
                           defaultValue: "Subtitle search failed. The server may not have a subtitle provider installed.")
                )
                return
            }
            selectSubtitleTrack(id: applied.index)
            dismissSubtitleSearch()
        } catch {
            subtitleSearchState = .error(
                String(localized: "player.subtitle.search.error",
                       defaultValue: "Subtitle search failed. The server may not have a subtitle provider installed.")
            )
        }
    }
}
