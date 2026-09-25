import Testing
import Foundation
@testable import Sodalite

/// The file sink's file taken off the device (AE#597): offered on the tvOS export page as a download,
/// and on iOS through the share sheet. The buffer export freezes its lines when it opens; these pin
/// that the file is frozen the same way, including through the two things the sink does to it while a
/// reporter is downloading: appending, and deleting it on a full re-arm.
struct PersistedLogFileTests {

    private static let environment = LogExportSession.Environment(
        appVersion: "1.0",
        build: "42",
        systemName: "tvOS",
        systemVersion: "26.6",
        hardware: "AppleTV14,1"
    )

    private static let capture = Date(timeIntervalSince1970: 1_800_000_000)

    private static func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("persisted-log-\(UUID().uuidString).txt")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private static func session(file: PersistedLogFile?) -> LogExportSession {
        LogExportSession(
            lines: ["[session] buffered line"],
            environment: environment,
            capturedAt: capture,
            persistedLog: file
        )
    }

    private static func get(_ path: String) -> String {
        "GET \(path) HTTP/1.1\r\nHost: 192.168.1.20:52341\r\n\r\n"
    }

    /// What a client receives: the serialized head and body, then the streamed file.
    private static func wire(_ response: LogExportResponse) -> String {
        var data = response.serialized
        response.file?.stream { data.append(contentsOf: $0); return true }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Freezing

    @Test("a missing or empty file is not offered")
    func nothingToOffer() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID()).txt")
        #expect(PersistedLogFile(url: missing) == nil)

        let empty = try Self.tempFile("")
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(PersistedLogFile(url: empty) == nil)
    }

    @Test("lines appended after the export opened are not handed over")
    func lengthIsFrozen() throws {
        let url = try Self.tempFile("first\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try #require(PersistedLogFile(url: url))

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("second\n".utf8))
        try handle.close()

        var read = Data()
        #expect(file.stream { read.append(contentsOf: $0); return true })
        #expect(String(decoding: read, as: UTF8.self) == "first\n")
    }

    /// `startFileSink` deletes and recreates a file at its cap. A download in flight must not come back
    /// short of its own `Content-Length`, which a browser waits out as a stalled transfer.
    @Test("the file survives being deleted and recreated underneath")
    func survivesReplacement() throws {
        let url = try Self.tempFile("evidence\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try #require(PersistedLogFile(url: url))

        try FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)

        var read = Data()
        #expect(file.stream { read.append(contentsOf: $0); return true })
        #expect(String(decoding: read, as: UTF8.self) == "evidence\n")
    }

    @Test("streaming crosses chunk boundaries without losing or repeating a byte")
    func streamsInChunks() throws {
        let contents = (0 ..< 5000).map { "line \($0)" }.joined(separator: "\n")
        let url = try Self.tempFile(contents)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try #require(PersistedLogFile(url: url))

        var read = Data()
        var chunks = 0
        #expect(file.stream(chunkSize: 1000) { read.append(contentsOf: $0); chunks += 1; return true })
        #expect(chunks > 1)
        #expect(String(decoding: read, as: UTF8.self) == contents)
    }

    @Test("a sink that refuses stops the stream")
    func refusingSinkStops() throws {
        let url = try Self.tempFile(String(repeating: "x", count: 10_000))
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try #require(PersistedLogFile(url: url))

        var calls = 0
        #expect(!file.stream(chunkSize: 1000) { _ in calls += 1; return false })
        #expect(calls == 1)
    }

    @Test("the share copy leads with its provenance and then the file verbatim")
    func copyCarriesHeader() throws {
        let url = try Self.tempFile("[player] line\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try #require(PersistedLogFile(url: url))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("copy-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: destination) }

        try file.writeCopy(to: destination, header: "Sodalite 1.0 (42)")

        #expect(try String(contentsOf: destination, encoding: .utf8) == "Sodalite 1.0 (42)\n\n[player] line\n")
    }

    // MARK: - Serving

    @Test("the page links the file only when there is one")
    func pageLinksFileWhenPresent() throws {
        let url = try Self.tempFile("[player] line\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let without = Self.session(file: nil)
        let pageWithout = String(decoding: without.response(to: Self.get("/\(without.token)"), now: Self.capture).body, as: UTF8.self)
        #expect(!pageWithout.contains(LogExportSession.persistedLogName))

        let with = Self.session(file: PersistedLogFile(url: url))
        let pageWith = String(decoding: with.response(to: Self.get("/\(with.token)"), now: Self.capture).body, as: UTF8.self)
        #expect(pageWith.contains("href=\"/\(with.token)/\(LogExportSession.persistedLogName)\" download"))
        #expect(
            pageWith.contains(String(localized: "settings.log.export.page.file.note")),
            "the persistent file is a different log than the page shows and says so (Sodalite#164)"
        )
        #expect(!pageWithout.contains(String(localized: "settings.log.export.page.file.note")))
    }

    @Test("the file route is a 404 when there is no file")
    func fileRouteWithoutFile() {
        let session = Self.session(file: nil)
        let response = session.response(
            to: Self.get("/\(session.token)/\(LogExportSession.persistedLogName)"),
            now: Self.capture
        )
        #expect(response.status == 404)
        #expect(response.file == nil)
    }

    @Test("the file route serves header plus file as a download with an exact length")
    func fileRouteServesDownload() throws {
        let contents = "[LogTap] file sink armed\n[player] Grüße\n"
        let url = try Self.tempFile(contents)
        defer { try? FileManager.default.removeItem(at: url) }
        let session = Self.session(file: PersistedLogFile(url: url))

        let response = session.response(
            to: Self.get("/\(session.token)/\(LogExportSession.persistedLogName)"),
            now: Self.capture
        )
        let wire = Self.wire(response)
        let split = try #require(wire.range(of: "\r\n\r\n"))
        let headers = String(wire[..<split.lowerBound])
        let body = String(wire[split.upperBound...])

        #expect(response.status == 200)
        #expect(headers.contains("Content-Disposition: attachment; filename=\"sodalite-persistent-log.txt\""))
        #expect(headers.contains("Content-Length: \(Data(body.utf8).count)"))
        #expect(body.hasPrefix("Sodalite 1.0 (42) - tvOS 26.6 - AppleTV14,1\nPersistent log, "))
        #expect(body.hasSuffix("\n\n" + contents))
    }

    @Test("an expired session does not serve the file")
    func expiredSessionHidesFile() throws {
        let url = try Self.tempFile("[player] line\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = Self.session(file: PersistedLogFile(url: url))

        let response = session.response(
            to: Self.get("/\(session.token)/\(LogExportSession.persistedLogName)"),
            now: Self.capture.addingTimeInterval(301)
        )
        #expect(response.status == 410)
        #expect(response.file == nil)
    }
}
