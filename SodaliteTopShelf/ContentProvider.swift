import os.log
@preconcurrency import TVServices

private let log = Logger(subsystem: "de.superuser404.Sodalite.TopShelf", category: "ContentProvider")

/// Top Shelf provider; tvOS calls loadTopShelfContent on icon focus + background refresh. No session or a transient API error both return nil (shelf falls back to the static brand asset).
///
/// `@objc(SodaliteTopShelfContentProvider)` pins an explicit Obj-C name so PluginKit's NSClassFromString lookup against NSExtensionPrincipalClass survives Swift name-mangling. The target also needs `OTHER_LDFLAGS = -e _NSExtensionMain` (Xcode sets it automatically, hand-rolled pbxproj targets do not).
@objc(SodaliteTopShelfContentProvider)
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        // Protocol-witness dispatch so the reader's deprecation marker doesn't propagate here.
        let reader: any TVUserTokenReading = TVUserTokenReader()
        let tvUserID = reader.currentToken()
        guard let session = SharedSession.read(tvUserID: tvUserID) else {
            log.notice("No shared session in keychain; TopShelf will render empty.")
            return nil
        }
        let api = JellyfinAPI(session: session)

        async let resume = Self.fetch("resume") { try await api.resumeItems() }
        async let nextUp = Self.fetch("nextUp") { try await api.nextUp() }

        let fetchedResume = await resume
        let fetchedNextUp = await nextUp

        let stored = TopShelfCache.read()
        let cached = stored.flatMap { cache in
            TopShelfCachePolicy.matches(cachedServerURL: cache.serverURL,
                                        cachedUserID: cache.userID,
                                        sessionServerURL: session.baseURL.absoluteString,
                                        sessionUserID: session.userID) ? cache : nil
        }
        if cached == nil, stored != nil {
            // Belongs to a session we are no longer in; don't carry it forward.
            TopShelfCachePolicy.delete()
        }

        let resumeItems = fetchedResume ?? cached?.resume ?? []
        let nextUpItems = fetchedNextUp ?? cached?.nextUp ?? []
        log.info("Fetched resume=\(resumeItems.count) nextUp=\(nextUpItems.count) fromCache=\(fetchedResume == nil || fetchedNextUp == nil)")

        // Writes the merged view, not just what came back, so a partial failure still leaves
        // both sections populated for the next total failure.
        if TopShelfCachePolicy.shouldWrite(resumeSucceeded: fetchedResume != nil,
                                           nextUpSucceeded: fetchedNextUp != nil) {
            TopShelfCache(serverURL: session.baseURL.absoluteString,
                          userID: session.userID,
                          resume: resumeItems,
                          nextUp: nextUpItems).write()
        }

        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []

        if !resumeItems.isEmpty {
            let collection = TVTopShelfItemCollection(items: resumeItems.map {
                makeItem(item: $0, session: session)
            })
            collection.title = String(
                localized: "TopShelf.ContinueWatching",
                defaultValue: "Continue Watching"
            )
            sections.append(collection)
        }

        if !nextUpItems.isEmpty {
            let collection = TVTopShelfItemCollection(items: nextUpItems.map {
                makeItem(item: $0, session: session)
            })
            collection.title = String(
                localized: "TopShelf.NextUp",
                defaultValue: "Next Up"
            )
            sections.append(collection)
        }

        guard !sections.isEmpty else { return nil }
        return TVTopShelfSectionedContent(sections: sections)
    }


    private func makeItem(item: JellyfinItem, session: SharedSession) -> TVTopShelfSectionedItem {
        let cell = TVTopShelfSectionedItem(identifier: item.id)
        cell.title = item.topShelfTitle
        cell.imageShape = .hdtv
        cell.displayAction = TVTopShelfAction(url: detailLink(for: item))
        cell.playAction = TVTopShelfAction(url: playLink(for: item))
        if let progress = item.topShelfProgress {
            cell.playbackProgress = progress
        }

        if let url = item.topShelfImageURL(baseURL: session.baseURL, token: session.accessToken) {
            // 2x is the only scale Apple TV renders; setting both 1x and 2x doubles the daemon's fetch work and trips memory pressure surfacing as "-17102 decompressing image" when cells race to decode.
            cell.setImageURL(url, for: .screenScale2x)
        } else {
            log.notice("cell \(item.id, privacy: .public) has no image URL")
        }
        return cell
    }

    /// `sodalite://item/{id}`: handled by the main app's `onOpenURL` to push directly into the detail/player route for that item.
    private func detailLink(for item: JellyfinItem) -> URL {
        URL(string: "sodalite://item/\(item.id)")!
    }

    /// Same route, but the app starts playback on arrival. Bound to the cell's playAction, so the remote's Play button skips the detail page.
    private func playLink(for item: JellyfinItem) -> URL {
        URL(string: "sodalite://play/\(item.id)")!
    }

    /// nil is a failed fetch, [] is a genuinely empty section; the cache fallback needs to tell them apart.
    private static func fetch(_ label: String, _ work: () async throws -> [JellyfinItem]) async -> [JellyfinItem]? {
        do {
            return try await work()
        } catch {
            log.error("\(label, privacy: .public) fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Mirrors TVUserContext: `currentUserIdentifier` is deprecated (tvOS 16) but the only source of the per-user token the session mirror is keyed by; the entitlement replacement would remove identity entirely. Deliberately kept; protocol dispatch confines the deprecation warning to the impl.
private protocol TVUserTokenReading {
    func currentToken() -> String?
}

private struct TVUserTokenReader: TVUserTokenReading {
    @available(tvOS, deprecated: 16.0, message: "Deliberate: only source of the per-user token.")
    func currentToken() -> String? {
        if #available(tvOS 13, *) {
            return TVUserManager().currentUserIdentifier
        }
        return nil
    }
}
