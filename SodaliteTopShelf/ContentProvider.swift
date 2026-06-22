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
            log.notice("No shared session in keychain — TopShelf will render empty.")
            return nil
        }
        let api = JellyfinAPI(session: session)

        async let resume = Self.fetch("resume") { try await api.resumeItems() }
        async let nextUp = Self.fetch("nextUp") { try await api.nextUp() }

        let resumeItems = await resume
        let nextUpItems = await nextUp
        log.info("Fetched resume=\(resumeItems.count) nextUp=\(nextUpItems.count)")

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
        cell.displayAction = TVTopShelfAction(url: deepLink(for: item))

        if let url = item.topShelfImageURL(baseURL: session.baseURL, token: session.accessToken) {
            // 2x is the only scale Apple TV actually renders — setting
            // both 1x and 2x doubles the daemon's fetch work and trips
            // memory pressure that can surface as "-17102 decompressing
            // image" when several cells race to decode at once.
            cell.setImageURL(url, for: .screenScale2x)
        } else {
            log.notice("cell \(item.id, privacy: .public) has no image URL")
        }
        return cell
    }

    /// `sodalite://item/{id}` — handled by the main app's
    /// `onOpenURL` to push directly into the detail/player route
    /// for that item.
    private func deepLink(for item: JellyfinItem) -> URL {
        URL(string: "sodalite://item/\(item.id)")!
    }

    private static func fetch(_ label: String, _ work: () async throws -> [JellyfinItem]) async -> [JellyfinItem] {
        do {
            return try await work()
        } catch {
            log.error("\(label, privacy: .public) fetch failed: \(error.localizedDescription, privacy: .public)")
            return []
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
