import Foundation
import os
import os.log

/// The Top Shelf's diagnostic lines, on their way to Settings > Diagnostic Log as well as to OSLog.
///
/// This code runs in two processes, and before this neither reached `LogTap`: the extension because it
/// is a separate process, the app's pre-render pass because it logged through a bare `Logger`. A report
/// could say what the shelf looked like but not which pass drew it (Sodalite#128). In the app `sink` is
/// set and a line goes straight into the buffer. The extension has no way into the app's memory, so its
/// lines go to `ShelfLogFile` and the app drains that file when it becomes active.
///
/// Redaction happens here, before either destination, so the file on disk never holds a credential and
/// neither does the OSLog copy.
nonisolated struct ShelfLog: Sendable {

    private let category: String
    private let logger: Logger

    init(category: String) {
        self.category = category
        logger = Logger(subsystem: "de.superuser404.Sodalite.TopShelf", category: category)
    }

    func info(_ message: String) {
        let message = LogRedaction.redact(message)
        logger.info("\(message, privacy: .public)")
        forward(message)
    }

    func notice(_ message: String) {
        let message = LogRedaction.redact(message)
        logger.notice("\(message, privacy: .public)")
        forward(message)
    }

    func error(_ message: String) {
        let message = LogRedaction.redact(message)
        logger.error("\(message, privacy: .public)")
        forward(message)
    }

    /// Set once by the app at launch and never in the extension, which is how a line knows which
    /// process wrote it.
    static var sink: (@Sendable (String) -> Void)? {
        get { sinkStorage.withLock { $0 } }
        set { sinkStorage.withLock { $0 = newValue } }
    }

    private static let sinkStorage = OSAllocatedUnfairLock<(@Sendable (String) -> Void)?>(initialState: nil)

    /// The prefix names the process, because the same pass runs in both and "the app rendered it" and
    /// "the extension rendered it" are different answers to a shelf bug.
    static func line(category: String, message: String, inApp: Bool) -> String {
        "[TopShelf \(inApp ? "app" : "ext")/\(category)] \(message)"
    }

    private func forward(_ message: String) {
        if let sink = Self.sink {
            sink(Self.line(category: category, message: message, inApp: true))
        } else {
            ShelfLogFile.shared?.append(Self.line(category: category, message: message, inApp: false))
        }
    }
}

/// The extension's half of `ShelfLog`: a small file in the group container that the app drains.
///
/// `NSFileCoordinator` on both sides, because the two processes can overlap: the app asks tvOS to reload
/// the shelf while it is in front, and the extension answers while the app may be draining. The file is
/// capped and trimmed at a line boundary, so a shelf that reloads for days with the app never opened
/// holds its most recent lines rather than growing.
///
/// On a multi-user Apple TV the extension runs as the Default user (see CLAUDE.md), so its lines land in
/// that user's container and only that user's app sees them.
nonisolated struct ShelfLogFile: Sendable {

    static let fileName = "topshelf-log.txt"

    /// Several hundred lines. One extension pass writes about ten.
    static let capBytes = 64 * 1024

    let url: URL

    /// `Library/Caches`, the only writable place in a tvOS group container besides Preferences.
    static var shared: ShelfLogFile? {
        TopShelfCachePolicy.directory().map { ShelfLogFile(url: $0.appendingPathComponent(fileName)) }
    }

    func append(_ line: String, at date: Date = Date()) {
        let entry = Data("\(LogTimestamp.stamp(date))  \(line)\n".utf8)
        coordinate { url in
            var data = (try? Data(contentsOf: url)) ?? Data()
            data.append(entry)
            if data.count > Self.capBytes {
                data = Self.trimmed(data)
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Every line written since the last drain, oldest first, and the file is gone afterwards so a line
    /// is handed over once.
    func drain() -> [String] {
        var lines: [String] = []
        coordinate(options: .forDeleting) { url in
            guard let data = try? Data(contentsOf: url) else { return }
            try? FileManager.default.removeItem(at: url)
            lines = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map(String.init)
        }
        return lines
    }

    /// Keeps the newer half, starting after a newline so the first kept line is whole.
    static func trimmed(_ data: Data) -> Data {
        let cut = data.index(data.endIndex, offsetBy: -(capBytes / 2))
        guard let newline = data[cut...].firstIndex(of: UInt8(ascii: "\n")) else { return Data() }
        return Data(data[data.index(after: newline)...])
    }

    private func coordinate(options: NSFileCoordinator.WritingOptions = [], _ body: (URL) -> Void) {
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: options, error: &error, byAccessor: body)
    }
}
