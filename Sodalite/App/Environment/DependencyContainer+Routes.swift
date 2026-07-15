import Foundation

/// Dual-URL route resolution. Synchronous session paths set an optimistic
/// baseURL via preferredURL(lastKnown:) for first-frame correctness; this
/// extension then probes and corrects asynchronously. A route change only
/// affects new requests; active playback keeps its absolute stream URL.
extension DependencyContainer {
    /// Debounce/cancel seam for the iOS path-change and foreground triggers.
    func scheduleRouteResolve() {
        routeResolveTask?.cancel()
        routeResolveTask = Task { [weak self] in
            await self?.resolveActiveRoutes()
        }
    }

    func resolveActiveRoutes() async {
        await resolveJellyfinRoute()
        await resolveSeerrRoute()
    }

    private func resolveJellyfinRoute() async {
        guard let server = activeServer else {
            activeJellyfinRoute = nil
            return
        }
        guard let resolved = await ServerRouteResolver.resolve(
            internalURL: server.internalURL,
            externalURL: server.externalURL,
            lastKnown: serverRouteStore.lastRoute(serverID: server.id),
            probe: { await ServerProbe.jellyfin($0) }
        ) else { return }
        guard !Task.isCancelled else { return }

        serverRouteStore.setLastRoute(resolved.route, serverID: server.id)
        activeJellyfinRoute = resolved.route
        guard jellyfinClient.baseURL != resolved.url else { return }

        jellyfinClient.baseURL = resolved.url
        rewriteSessionMirror(server: server, resolvedURL: resolved.url)
        NotificationCenter.default.post(name: .serverRouteDidChange, object: nil)
    }

    private func resolveSeerrRoute() async {
        guard let server = appState?.activeSeerrServer, seerrClient.sessionCookie != nil else {
            activeSeerrRoute = nil
            return
        }
        guard let resolved = await ServerRouteResolver.resolve(
            internalURL: server.internalURL,
            externalURL: server.externalURL,
            lastKnown: serverRouteStore.lastRoute(serverID: seerrRouteKey(server.id)),
            probe: { await ServerProbe.seerr($0) }
        ) else { return }
        guard !Task.isCancelled else { return }

        serverRouteStore.setLastRoute(resolved.route, serverID: seerrRouteKey(server.id))
        activeSeerrRoute = resolved.route
        guard seerrClient.baseURL != resolved.url else { return }

        seerrClient.baseURL = resolved.url
        NotificationCenter.default.post(name: .serverRouteDidChange, object: nil)
    }

    /// Jellyfin and Seerr ids live in the same store; prefix avoids collisions.
    func seerrRouteKey(_ id: String) -> String { "seerr.\(id)" }

    func preferredURL(for server: JellyfinServer) -> URL {
        server.preferredURL(lastKnown: serverRouteStore.lastRoute(serverID: server.id))
    }

    func preferredSeerrURL(for server: SeerrServer) -> URL {
        server.preferredURL(lastKnown: serverRouteStore.lastRoute(serverID: seerrRouteKey(server.id)))
    }

    /// TopShelf reads absolute image URLs from the mirror; keep it on the live route.
    private func rewriteSessionMirror(server: JellyfinServer, resolvedURL: URL) {
        guard
            let token = try? keychainService.loadString(for: KeychainKeys.accessToken(serverID: server.id)),
            let userID = try? keychainService.loadString(for: KeychainKeys.userID(serverID: server.id))
        else { return }
        SharedSessionMirror.write(
            tvUserID: TVUserContext.currentUserID,
            serverURL: resolvedURL,
            userID: userID,
            accessToken: token
        )
    }
}
