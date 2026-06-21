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
        let language = subtitleSearchLanguage
        do {
            let raw = try await searchRemoteSubtitlesWithRetry(language: language)
            // A late-returning search whose language the user has since
            // switched away from must not overwrite the newer query's state.
            guard language == subtitleSearchLanguage else { return }
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
            guard language == subtitleSearchLanguage else { return }
            subtitleSearchState = .error(
                String(localized: "player.subtitle.search.error",
                       defaultValue: "Subtitle search failed. The server may not have a subtitle provider installed.")
            )
            subtitleSearchFocus = .language(subtitleSearchCurrentLanguageIndex)
        }
    }

    /// Runs the RemoteSearch, retrying once on failure. The server's
    /// OpenSubtitles provider frequently cold-starts on the first query of a
    /// session and that initial request times out, while an immediate retry
    /// succeeds, the same "just search again" that worked manually. Retrying
    /// once here keeps that hiccup from surfacing the scary (and wrong) "no
    /// provider installed" message.
    private func searchRemoteSubtitlesWithRetry(language: String) async throws -> [RemoteSubtitleInfo] {
        do {
            return try await playbackService.searchRemoteSubtitles(itemID: item.id, language: language)
        } catch {
            LogTap.shared.note("[SubSearch] first attempt failed (\(error)); retrying once")
            try await Task.sleep(for: .milliseconds(400))
            return try await playbackService.searchRemoteSubtitles(itemID: item.id, language: language)
        }
    }

    /// Downloads `info` server-side, refetches the active media source's
    /// streams to find the newly attached external subtitle, lists it,
    /// applies it live, and dismisses the overlay. If the server has not
    /// attached the track by the time polling stops (typical on a slow CDN),
    /// drops into `.downloadTimedOut` so the overlay can offer "Try again".
    func downloadAndApplySubtitle(_ info: RemoteSubtitleInfo) async {
        subtitleSearchState = .downloading(id: info.id)
        // External subtitles are never collapsed by the dedupe, so the
        // current `subtitleStreams` already lists every external track; its
        // index set is a sound "before" snapshot for spotting the newly
        // attached one.
        let before = Set(subtitleStreams.map(\.index))
        do {
            try await playbackService.downloadRemoteSubtitle(itemID: item.id, subtitleID: info.id)
        } catch {
            // The download request itself failed (network/server error). That
            // is a genuine failure, not the slow-CDN "still fetching" case.
            subtitleSearchState = .error(
                String(localized: "player.subtitle.search.downloadFailed",
                       defaultValue: "Could not download this subtitle. Please try another one.")
            )
            subtitleSearchFocus = .language(subtitleSearchCurrentLanguageIndex)
            return
        }
        await applyNewlyAttachedSubtitle(info: info, before: before)
    }

    /// Re-checks whether the timed-out download has since been attached by
    /// the server, without re-issuing the download. Backs the overlay's
    /// "Try again" button.
    func retryTimedOutDownload() async {
        guard case .downloadTimedOut(let info, let before, _) = subtitleSearchState else { return }
        subtitleSearchState = .downloading(id: info.id)
        await applyNewlyAttachedSubtitle(info: info, before: before)
    }

    /// Polls PlaybackInfo for a new external subtitle not present in
    /// `before`. On success applies it live and dismisses the overlay; on
    /// timeout parks in `.downloadTimedOut` with the pending message and
    /// focuses the retry button. Per-attempt PlaybackInfo errors are
    /// swallowed so a transient hiccup on a slow CDN reads as "still
    /// fetching", not a hard failure.
    private func applyNewlyAttachedSubtitle(info: RemoteSubtitleInfo, before: Set<Int>) async {
        var newStream: MediaStream?
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(600)) }
            guard let response = try? await playbackService.getPlaybackInfo(
                itemID: item.id, userID: userID, profile: nil
            ) else { continue }
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
            // The download was accepted but the server had not attached the
            // track yet. On a slow server/CDN the fetch often finishes
            // seconds later, so this is a "still working" state, not an
            // outright failure: show the pending copy and let the user
            // re-check with "Try again" once it has had a moment.
            subtitleSearchState = .downloadTimedOut(
                info: info,
                before: before,
                message: String(localized: "player.subtitle.search.downloadPending",
                                defaultValue: "The download is taking longer than expected. The server may still be fetching it on a slow connection. Wait a moment, then tap Try again.")
            )
            subtitleSearchFocus = .retry
            return
        }
        selectSubtitleTrack(id: applied.index)
        dismissSubtitleSearch()
        // Resume the controls auto-hide timer that opening the dropdown
        // cancelled, so the transport UI fades out as after any picker.
        scheduleControlsHide()
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
            if !currentSubtitleResults.isEmpty {
                subtitleSearchFocus = .result(0)
            } else if isSubtitleDownloadTimedOut {
                subtitleSearchFocus = .retry
            }
        case .result(let i):
            if i + 1 < currentSubtitleResults.count { subtitleSearchFocus = .result(i + 1) }
        case .retry:
            break
        }
    }

    func subtitleSearchMoveUp() {
        switch subtitleSearchFocus {
        case .language:
            break
        case .result(let i):
            subtitleSearchFocus = i > 0 ? .result(i - 1) : .language(subtitleSearchCurrentLanguageIndex)
        case .retry:
            // Back up to the language row so the user can change language and
            // run a fresh search instead of waiting on the stuck download.
            subtitleSearchFocus = .language(subtitleSearchCurrentLanguageIndex)
        }
    }

    /// Activates the highlighted element: switch language, download a result,
    /// or re-check a timed-out download.
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
        case .retry:
            Task { [weak self] in await self?.retryTimedOutDownload() }
        }
    }

    /// True while the overlay is parked on a timed-out download.
    private var isSubtitleDownloadTimedOut: Bool {
        if case .downloadTimedOut = subtitleSearchState { return true }
        return false
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
