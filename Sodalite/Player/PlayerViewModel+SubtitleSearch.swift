import Foundation

/// Feature #4: in-player subtitle search/download via Jellyfin
/// RemoteSearch (server needs the OpenSubtitles plugin). Downloaded
/// subtitles are attached server-side as external streams, then applied
/// live through the existing sidecar subtitle path.
@MainActor
extension PlayerViewModel {

    /// ISO 639-2/T codes (what `Locale` emits) mapped to /B codes (what
    /// the curated language list and Jellyfin use) for the languages
    /// where the two variants differ. Only entries that appear in
    /// `subtitleSearchLanguageOptions` matter here.
    private static let alpha3TtoB: [String: String] = [
        "deu": "ger", "fra": "fre", "ces": "cze", "nld": "dut",
        "ell": "gre", "ron": "rum", "zho": "chi"
    ]

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
        let deviceCode = Locale.current.language.languageCode?.identifier(.alpha3)
            .map { Self.alpha3TtoB[$0] ?? $0 }
        let seed = preferences.preferredSubtitleLanguage ?? deviceCode ?? "eng"
        subtitleSearchLanguage = seed
        subtitleSearchFocus = .language(subtitleSearchCurrentLanguageIndex)
        subtitleSearchVisible = true
        Task { [weak self] in await self?.searchSubtitles() }
    }

    func dismissSubtitleSearch() {
        subtitleSearchVisible = false
        subtitleSearchState = .idle
    }

    /// Switches the search language and re-runs the search.
    func setSubtitleSearchLanguage(_ code: String) {
        guard code != subtitleSearchLanguage else { return }
        subtitleSearchLanguage = code
        Task { [weak self] in await self?.searchSubtitles() }
    }

    /// Runs a RemoteSearch for the current language and fills state.
    func searchSubtitles() async {
        subtitleSearchState = .loading
        do {
            let results = try await playbackService.searchRemoteSubtitles(
                itemID: item.id,
                language: subtitleSearchLanguage
            )
            if results.isEmpty {
                subtitleSearchState = .empty
                subtitleSearchFocus = .language(subtitleSearchCurrentLanguageIndex)
            } else {
                subtitleSearchState = .results(results)
                subtitleSearchFocus = .result(0)
            }
        } catch {
            subtitleSearchState = .error(
                String(localized: "player.subtitle.search.error",
                       defaultValue: "Subtitle search failed. The server may not have a subtitle provider installed.")
            )
            subtitleSearchFocus = .language(subtitleSearchCurrentLanguageIndex)
        }
    }

    /// Downloads `info` server-side, refetches the active media source's
    /// streams to find the newly attached external subtitle, lists it,
    /// applies it live, and dismisses the overlay.
    func downloadAndApplySubtitle(_ info: RemoteSubtitleInfo) async {
        subtitleSearchState = .downloading(id: info.id)
        do {
            // External subtitles are never collapsed by the dedupe, so the
            // current `subtitleStreams` already lists every external track;
            // its index set is a sound "before" snapshot for spotting the
            // newly attached one.
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
                    String(localized: "player.subtitle.search.downloadFailed",
                           defaultValue: "Could not download this subtitle. Please try another one.")
                )
                return
            }
            selectSubtitleTrack(id: applied.index)
            dismissSubtitleSearch()
        } catch {
            subtitleSearchState = .error(
                String(localized: "player.subtitle.search.downloadFailed",
                       defaultValue: "Could not download this subtitle. Please try another one.")
            )
        }
    }

    // MARK: - Host-driven focus navigation

    /// Index of the currently searched language within the option list.
    var subtitleSearchCurrentLanguageIndex: Int {
        subtitleSearchLanguageOptions.firstIndex { $0.code == subtitleSearchLanguage } ?? 0
    }

    /// The results currently displayed, or empty.
    private var currentSubtitleResults: [RemoteSubtitleInfo] {
        if case .results(let r) = subtitleSearchState { return r }
        return []
    }

    func subtitleSearchMoveLeft() {
        if case .language(let i) = subtitleSearchFocus, i > 0 {
            subtitleSearchFocus = .language(i - 1)
        }
    }

    func subtitleSearchMoveRight() {
        if case .language(let i) = subtitleSearchFocus,
           i + 1 < subtitleSearchLanguageOptions.count {
            subtitleSearchFocus = .language(i + 1)
        }
    }

    func subtitleSearchMoveDown() {
        switch subtitleSearchFocus {
        case .language:
            if !currentSubtitleResults.isEmpty { subtitleSearchFocus = .result(0) }
        case .result(let i):
            if i + 1 < currentSubtitleResults.count { subtitleSearchFocus = .result(i + 1) }
        }
    }

    func subtitleSearchMoveUp() {
        switch subtitleSearchFocus {
        case .language:
            break
        case .result(let i):
            subtitleSearchFocus = i > 0 ? .result(i - 1) : .language(subtitleSearchCurrentLanguageIndex)
        }
    }

    /// Activates the highlighted element: switch language, or download a result.
    func subtitleSearchConfirm() {
        switch subtitleSearchFocus {
        case .language(let i):
            let opts = subtitleSearchLanguageOptions
            guard opts.indices.contains(i), let code = opts[i].code else { return }
            setSubtitleSearchLanguage(code)
        case .result(let i):
            let results = currentSubtitleResults
            guard results.indices.contains(i) else { return }
            Task { [weak self] in await self?.downloadAndApplySubtitle(results[i]) }
        }
    }
}
