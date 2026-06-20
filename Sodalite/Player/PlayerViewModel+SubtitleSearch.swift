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

    /// Re-fetches the active media source's streams and refreshes the
    /// listed subtitle tracks. Used to surface subtitles that the server
    /// attached after we last looked, e.g. a download that finished late on
    /// a slow CDN. Best-effort and silent: any error leaves the current
    /// list untouched so opening the menu never blocks or shows an error.
    /// Skipped for live sessions, which have no library item to query.
    func refreshSubtitleStreams() async {
        guard supportsSubtitleSearch else { return }
        guard let response = try? await playbackService.getPlaybackInfo(
            itemID: item.id, userID: userID, profile: nil
        ) else { return }
        guard let source = response.mediaSources.first(where: { $0.id == mediaSourceID })
            ?? response.mediaSources.first else { return }
        let refreshed = Self.dedupedSubtitleStreams(from: source.mediaStreams)
        // Only reassign when something actually changed, to avoid needless
        // view churn while the dropdown is open.
        if refreshed.map(\.index) != subtitleStreams.map(\.index) {
            subtitleStreams = refreshed
        }
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
            let raw = try await playbackService.searchRemoteSubtitles(
                itemID: item.id,
                language: subtitleSearchLanguage
            )
            // Hash matches are timed against this exact file (perfect
            // sync); surface them first, then order by popularity.
            let results = raw.sorted { lhs, rhs in
                if (lhs.isHashMatch == true) != (rhs.isHashMatch == true) {
                    return lhs.isHashMatch == true
                }
                return (lhs.downloadCount ?? 0) > (rhs.downloadCount ?? 0)
            }
            // Diagnostic: how many of the server's results are hash matches
            // (exact-file timing). 0 => no "Exact match" badge is expected
            // for this file, which is normal when OpenSubtitles has no
            // hash-keyed entry for it.
            let hashMatchCount = results.filter { $0.isHashMatch == true }.count
            LogTap.shared.note("[SubSearch] lang=\(subtitleSearchLanguage) results=\(results.count) hashMatch=\(hashMatchCount)")
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
                // The download request was accepted, but the server had not
                // attached the track by the time we stopped polling. On a slow
                // server/CDN the fetch often finishes seconds later, so this is
                // a "still working" state, not an outright failure: tell the
                // user it may still arrive and that reopening the menu will pick
                // it up (the menu now refreshes itself on open).
                subtitleSearchState = .error(
                    String(localized: "player.subtitle.search.downloadPending",
                           defaultValue: "The download is taking longer than expected. The server may still be fetching it on a slow connection. Reopen the subtitle menu in a moment and it should appear.")
                )
                return
            }
            selectSubtitleTrack(id: applied.index)
            dismissSubtitleSearch()
            // Resume the controls auto-hide timer that opening the dropdown
            // cancelled, so the transport UI fades out as after any picker.
            scheduleControlsHide()
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

    // MARK: - Delete external subtitle (hold-to-delete)

    /// Opens the delete confirmation for the external subtitle at
    /// `streamIndex`. Closes the dropdown so the prompt takes over.
    func requestSubtitleDeletion(streamIndex: Int) {
        subtitleDeleteFocus = .cancel
        subtitleDeleteState = .confirm(streamIndex: streamIndex)
        trackDropdown = .none
    }

    /// Toggles the highlighted button in the delete prompt (left/right).
    func subtitleDeletePromptToggleFocus() {
        guard case .confirm = subtitleDeleteState else { return }
        subtitleDeleteFocus = subtitleDeleteFocus == .cancel ? .delete : .cancel
    }

    /// Select press on the delete prompt: confirm (Delete) or dismiss.
    func subtitleDeletePromptConfirm() {
        switch subtitleDeleteState {
        case .confirm(let streamIndex):
            if subtitleDeleteFocus == .delete {
                subtitleDeleteState = .deleting
                Task { [weak self] in await self?.performSubtitleDeletion(streamIndex: streamIndex) }
            } else {
                subtitleDeleteState = .hidden
                scheduleControlsHide()
            }
        case .error:
            subtitleDeleteState = .hidden
            scheduleControlsHide()
        case .deleting, .hidden:
            break
        }
    }

    /// Menu/back on the delete prompt: dismiss (ignored mid-deletion).
    func subtitleDeletePromptDismiss() {
        if case .deleting = subtitleDeleteState { return }
        subtitleDeleteState = .hidden
        scheduleControlsHide()
    }

    private func performSubtitleDeletion(streamIndex: Int) async {
        // If we're deleting the active track, turn subtitles off first.
        if activeSubtitleIndex == streamIndex { selectSubtitleTrack(id: nil) }
        do {
            try await playbackService.deleteSubtitle(itemID: item.id, index: streamIndex)
            let response = try await playbackService.getPlaybackInfo(
                itemID: item.id, userID: userID, profile: nil
            )
            if let source = response.mediaSources.first(where: { $0.id == mediaSourceID })
                ?? response.mediaSources.first {
                subtitleStreams = Self.dedupedSubtitleStreams(from: source.mediaStreams)
            }
            subtitleDeleteState = .hidden
            scheduleControlsHide()
        } catch {
            subtitleDeleteState = .error(
                String(localized: "player.subtitle.delete.failed",
                       defaultValue: "Could not delete the subtitle. You may not have permission.")
            )
        }
    }
}
