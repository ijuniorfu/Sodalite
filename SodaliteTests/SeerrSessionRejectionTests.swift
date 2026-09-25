import Testing
import Foundation
@testable import Sodalite

/// Audit 2026-09-25 CL-4. A Seerr session that dies mid-session left the Catalog on a Retry that could only
/// repeat the 401. SeerrClient is the one funnel every Seerr call takes, so it announces the rejection and
/// the Catalog re-probes the session.
@MainActor
struct SeerrSessionRejectionTests {

    private final class FailingHTTPClient: HTTPClientProtocol, @unchecked Sendable {
        let error: APIError
        var duringRequest: (() -> Void)?

        init(error: APIError) { self.error = error }

        func requestData(baseURL: URL, endpoint: APIEndpoint, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
            duringRequest?()
            throw error
        }
        func request<T: Decodable>(baseURL: URL, endpoint: APIEndpoint, headers: [String: String], responseType: T.Type) async throws -> T {
            throw error
        }
        func request(baseURL: URL, endpoint: APIEndpoint, headers: [String: String]) async throws { throw error }
    }

    private nonisolated final class Counter: @unchecked Sendable { var value = 0 }

    /// Counts only this client's posts: suites run in parallel and other clients post too.
    private func rejections(
        error: APIError,
        cookie: String?,
        endpoint: SeerrEndpoint = .authMe,
        duringRequest: ((SeerrClient) -> Void)? = nil
    ) async -> Int {
        let http = FailingHTTPClient(error: error)
        let client = SeerrClient(httpClient: http)
        client.baseURL = URL(string: "https://seerr.example")
        client.sessionCookie = cookie
        if let duringRequest { http.duringRequest = { duringRequest(client) } }

        let counter = Counter()
        let token = NotificationCenter.default.addObserver(
            forName: .seerrSessionRejected, object: client, queue: nil
        ) { _ in counter.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        _ = try? await client.requestData(endpoint: endpoint)
        return counter.value
    }

    @Test func a401OnTheHeldCookieIsAnnounced() async {
        #expect(await rejections(error: .unauthorized(message: nil), cookie: "connect.sid=a") == 1)
    }

    /// 403 is a permission answer (admin gates), not a dead session.
    @Test func a403IsNotASessionRejection() async {
        #expect(await rejections(error: .httpError(statusCode: 403, data: nil), cookie: "connect.sid=a") == 0)
    }

    @Test func a401WithoutACookieSaysNothingAboutASession() async {
        #expect(await rejections(error: .unauthorized(message: nil), cookie: nil) == 0)
    }

    /// The login POST carries no cookie on purpose; a wrong password is not a session verdict.
    @Test func aRefusedLoginIsNotASessionRejection() async {
        let login = SeerrEndpoint.authJellyfin(body: SeerrJellyfinAuthBody(username: "u", password: "p"))
        #expect(await rejections(error: .unauthorized(message: nil), cookie: "connect.sid=a", endpoint: login) == 0)
    }

    /// A profile switch installed another session while the request was out; the 401 was for the old one.
    @Test func aCookieSwappedMidRequestIsNotJudged() async {
        let count = await rejections(error: .unauthorized(message: nil), cookie: "connect.sid=a") { client in
            client.sessionCookie = "connect.sid=b"
        }
        #expect(count == 0)
    }
}
