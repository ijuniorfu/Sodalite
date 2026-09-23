import Testing
import Foundation
import Darwin
@testable import Sodalite

/// The half of Sodalite#148 that `LogExportSessionTests` cannot reach: a real listening socket, a real
/// client connecting to it from outside the app, and the bytes that come back.
///
/// Worth its own file rather than a manual check once, because the failure modes here are the ones that
/// only appear against a real peer: a read that stops before the blank line, a partial send, a listener
/// that survives `stop()`. The client below is raw BSD sockets rather than `URLSession` so nothing here
/// depends on App Transport Security's view of a cleartext address.
///
/// Skipped rather than failed when the machine has no `en*` interface, which is the one environment
/// difference that would otherwise make this red for a reason that has nothing to do with the code.
struct LogExportServerTests {

    /// `nonisolated` because the project defaults to MainActor isolation and `.enabled(if:)` evaluates
    /// its condition in a Sendable closure, off any actor.
    private nonisolated static var hasNetwork: Bool { LogExportServer.localAddress() != nil }

    private static let lines = [
        "[session] restoring user",
        "[player] direct play, HEVC 4K",
    ]

    /// One request, one response, connection closed. Returns the whole thing as a string.
    private static func fetch(port: UInt16, path: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0, "client socket")
        defer { close(fd) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(connected == 0, "connect failed errno=\(errno)")

        let request = Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        _ = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }

        var received = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = recv(fd, &chunk, chunk.count, 0)
            if read <= 0 { break }
            received.append(contentsOf: chunk[0 ..< read])
        }
        return String(decoding: received, as: UTF8.self)
    }

    /// Whether a connection can even be opened, which is what "the link is gone" has to mean once the
    /// deadline passes.
    private static func canConnect(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func port(of endpoint: LogExportServer.Endpoint) throws -> UInt16 {
        try #require(endpoint.url.port.flatMap { UInt16(exactly: $0) }, "no port in \(endpoint.url)")
    }

    private static func token(of endpoint: LogExportServer.Endpoint) -> String {
        endpoint.url.lastPathComponent
    }

    @Test("a started export answers a real connection with the page", .enabled(if: hasNetwork))
    func servesThePage() throws {
        let server = LogExportServer()
        defer { server.stop() }
        let endpoint = try server.start(lines: Self.lines)

        let response = try Self.fetch(port: try Self.port(of: endpoint), path: "/\(Self.token(of: endpoint))")

        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.contains("text/html"))
        #expect(response.contains("[player] direct play, HEVC 4K"))
    }

    /// The reader who wants the file rather than the page, and the one case where the body has to be
    /// byte for byte what the copy button would have produced.
    @Test("the text route returns the document and nothing around it", .enabled(if: hasNetwork))
    func servesTheDocument() throws {
        let server = LogExportServer()
        defer { server.stop() }
        let endpoint = try server.start(lines: Self.lines)

        let response = try Self.fetch(
            port: try Self.port(of: endpoint),
            path: "/\(Self.token(of: endpoint))/log.txt"
        )
        let body = try #require(response.range(of: "\r\n\r\n")).upperBound

        #expect(response.contains("Content-Type: text/plain; charset=utf-8"))
        #expect(String(response[body..<response.endIndex]).hasSuffix(Self.lines.joined(separator: "\n")))
    }

    /// AE#597. Larger than several stream chunks, so a partial send or a dropped chunk shows up as a
    /// body that is short of, or longer than, the file.
    @Test("the persistent log downloads whole over a real socket", .enabled(if: hasNetwork))
    func servesThePersistentLog() throws {
        let contents = (0 ..< 20_000).map { "[player] line \($0)" }.joined(separator: "\n")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID()).txt")
        try Data(contents.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = LogExportServer()
        defer { server.stop() }
        let endpoint = try server.start(lines: Self.lines, persistedLog: url)

        let response = try Self.fetch(
            port: try Self.port(of: endpoint),
            path: "/\(Self.token(of: endpoint))/\(LogExportSession.persistedLogName)"
        )
        let body = try #require(response.range(of: "\r\n\r\n")).upperBound

        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.contains("Content-Disposition: attachment"))
        #expect(String(response[body...]).hasSuffix("\n\n" + contents))
    }

    @Test("a wrong token gets nothing over the wire either", .enabled(if: hasNetwork))
    func rejectsWrongToken() throws {
        let server = LogExportServer()
        defer { server.stop() }
        let endpoint = try server.start(lines: Self.lines)

        let response = try Self.fetch(port: try Self.port(of: endpoint), path: "/not-the-token")

        #expect(response.hasPrefix("HTTP/1.1 404 "))
        #expect(!response.contains("[session] restoring user"))
    }

    /// The listener has to be gone, not merely unhelpful: a socket still accepting after the export was
    /// closed is a door left open for as long as the app runs.
    @Test("stopping closes the listener", .enabled(if: hasNetwork))
    func stopClosesTheListener() throws {
        let server = LogExportServer()
        let endpoint = try server.start(lines: Self.lines)
        let port = try Self.port(of: endpoint)
        #expect(Self.canConnect(port: port), "the port was not open while running")

        server.stop()

        #expect(!server.isRunning)
        #expect(!Self.canConnect(port: port), "the listener survived stop()")
    }

    /// Two exports in a row, which is what Try Again does after a link expires. The second must not
    /// inherit the first one's token, or a link read off a photograph of the old screen would still work.
    @Test("restarting draws a new token and a new port", .enabled(if: hasNetwork))
    func restartIsANewSession() throws {
        let server = LogExportServer()
        defer { server.stop() }

        let first = try server.start(lines: Self.lines)
        let firstToken = Self.token(of: first)
        let second = try server.start(lines: Self.lines)

        #expect(Self.token(of: second) != firstToken)

        let response = try Self.fetch(port: try Self.port(of: second), path: "/\(firstToken)")
        #expect(response.hasPrefix("HTTP/1.1 404 "), "the previous link still opened the log")
    }

    /// The deadline is the server's own, not the panel's: nothing in the UI has to be alive for the link
    /// to stop working.
    @Test("the link closes itself when its lifetime runs out", .enabled(if: hasNetwork))
    func expiresOnItsOwn() async throws {
        let server = LogExportServer()
        defer { server.stop() }
        let endpoint = try server.start(lines: Self.lines, lifetime: 1)
        let port = try Self.port(of: endpoint)

        try await Task.sleep(for: .seconds(2))

        #expect(!server.isRunning)
        #expect(!Self.canConnect(port: port))
    }
}
