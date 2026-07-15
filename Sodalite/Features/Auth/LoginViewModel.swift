import Foundation
import Observation

@Observable
final class LoginViewModel {
    var username = ""
    var password = ""
    var isLoading = false
    var errorMessage: String?
    var loginSucceeded = false

    var quickConnectCode: String?
    var isPollingQuickConnect = false

    // savedPassword set only for regular (non-Quick-Connect) logins; cached in keychain so Seerr can reuse it.
    var authResult: (server: JellyfinServer, user: JellyfinUser, token: String, savedPassword: String?)?

    let server: JellyfinServer

    private let authService: JellyfinAuthServiceProtocol
    private let keychainService: KeychainServiceProtocol
    private let dependencies: DependencyContainer
    /// Kept to backfill `primaryImageTag` from `/Users/Public`: some Jellyfin omit the tag on the auth response, else the avatar disappears after login.
    private let preSelectedUser: JellyfinUser?
    private var quickConnectSecret: String?
    private var quickConnectTask: Task<Void, Never>?

    init(
        server: JellyfinServer,
        preSelectedUser: JellyfinUser? = nil,
        dependencies: DependencyContainer
    ) {
        self.server = server
        self.authService = dependencies.jellyfinAuthService
        self.keychainService = dependencies.keychainService
        self.dependencies = dependencies
        self.preSelectedUser = preSelectedUser
        // Pre-fill username when picked from `/Users/Public`, leaving only the password to enter.
        if let preSelectedUser {
            self.username = preSelectedUser.name
        }
        dependencies.jellyfinClient.baseURL = dependencies.preferredURL(for: server)
    }

    func login() async {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        isLoading = true
        errorMessage = nil

        do {
            let response = try await authService.login(username: username, password: password)
            authResult = (server, enriched(response.user), response.accessToken, password)
            isLoading = false
            loginSucceeded = true
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// Backfills `primaryImageTag` from the picker's user, but only when the IDs match so we never mislabel an avatar.
    private func enriched(_ user: JellyfinUser) -> JellyfinUser {
        guard user.primaryImageTag == nil,
              let preSelectedUser,
              preSelectedUser.id == user.id,
              let tag = preSelectedUser.primaryImageTag
        else { return user }
        return JellyfinUser(
            id: user.id,
            name: user.name,
            serverID: user.serverID,
            hasPassword: user.hasPassword,
            primaryImageTag: tag,
            policy: user.policy
        )
    }

    func startQuickConnect() async {
        errorMessage = nil

        do {
            let response = try await authService.initiateQuickConnect()
            quickConnectCode = response.code
            quickConnectSecret = response.secret
            isPollingQuickConnect = true
            startPolling()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopQuickConnect() {
        quickConnectTask?.cancel()
        quickConnectTask = nil
        isPollingQuickConnect = false
        quickConnectCode = nil
        quickConnectSecret = nil
    }

    private func startPolling() {
        quickConnectTask?.cancel()
        quickConnectTask = Task { [weak self] in
            guard let self, let secret = self.quickConnectSecret else { return }

            // Hard cap for servers that keep answering "not authorized" without ever invalidating the secret, so the UI can't show a dead code forever.
            let deadline = Date().addingTimeInterval(6 * 60)

            while !Task.isCancelled && self.isPollingQuickConnect {
                guard Date() < deadline else {
                    self.expireQuickConnect()
                    return
                }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }

                do {
                    let isAuthorized = try await self.authService.checkQuickConnect(secret: secret)
                    if isAuthorized {
                        self.isPollingQuickConnect = false
                        await self.authenticateQuickConnect()
                        return
                    }
                } catch let error as APIError where error.isNotFound || error.isUnauthorized {
                    // Server no longer knows the secret (expired/consumed); polling can't succeed, so surface it.
                    self.expireQuickConnect()
                    return
                } catch {
                    // Transient network error: keep polling.
                }
            }
        }
    }

    private func expireQuickConnect() {
        stopQuickConnect()
        errorMessage = String(
            localized: "login.quickConnect.expired",
            defaultValue: "The code expired. Request a new one."
        )
    }

    private func authenticateQuickConnect() async {
        guard let secret = quickConnectSecret else { return }

        isLoading = true
        errorMessage = nil

        do {
            let response = try await authService.authenticateWithQuickConnect(secret: secret)
            authResult = (server, enriched(response.user), response.accessToken, String?.none)
            isLoading = false
            loginSucceeded = true
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func finalizeAuth() throws {
        guard let result = authResult else { return }
        try dependencies.saveSession(
            server: result.server,
            user: result.user,
            token: result.token,
            password: result.savedPassword
        )
    }
}
