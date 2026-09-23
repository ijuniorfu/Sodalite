import Foundation

/// The file sink's files (AE#597), frozen at the moment someone asked to take them off the device, and
/// handed over as one: the rotated half first, then the live one, which is the order they were written.
///
/// Holds open descriptors and the lengths they had then, not paths. The sink keeps appending while a
/// reporter downloads, and a rotation renames the live file and deletes the older half; a descriptor
/// keeps the bytes that were there readable through all of it, and the lengths keep what is handed
/// over from moving, the same rule `LogExportSession` applies to the buffer.
///
/// Read with `pread`, so concurrent requests for it never share a file offset.
nonisolated final class PersistedLogFile: Sendable {
    private struct Segment {
        let fd: Int32
        let length: Int
    }

    let length: Int
    private let segments: [Segment]

    /// Nil when there is nothing worth offering: no file, or only ones the sink never wrote a line to.
    /// Missing and empty files among `urls` are skipped.
    init?(urls: [URL]) {
        var segments: [Segment] = []
        for url in urls {
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { continue }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_size > 0 else {
                close(fd)
                continue
            }
            segments.append(Segment(fd: fd, length: Int(info.st_size)))
        }
        guard !segments.isEmpty else { return nil }
        self.segments = segments
        self.length = segments.reduce(0) { $0 + $1.length }
    }

    convenience init?(url: URL) {
        self.init(urls: [url])
    }

    deinit {
        for segment in segments {
            close(segment.fd)
        }
    }

    /// Hands the frozen bytes to `sink` in bounded chunks, so 32 MB never sit in memory whole.
    /// Stops early when `sink` returns false (the peer went away). Returns whether every byte went out.
    @discardableResult
    func stream(chunkSize: Int = 64 * 1024, into sink: (UnsafeRawBufferPointer) -> Bool) -> Bool {
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        for segment in segments {
            var offset = 0
            while offset < segment.length {
                let wanted = min(chunkSize, segment.length - offset)
                let read = buffer.withUnsafeMutableBytes { pread(segment.fd, $0.baseAddress, wanted, off_t(offset)) }
                guard read > 0 else { return false }
                let delivered = buffer.withUnsafeBytes { sink(UnsafeRawBufferPointer(rebasing: $0[0 ..< read])) }
                guard delivered else { return false }
                offset += read
            }
        }
        return true
    }

    /// A standalone copy with `header` on top, for the iOS share sheet. The header is the same
    /// provenance line the buffer export leads with, so a file that arrives without its conversation
    /// still says which build wrote it.
    func writeCopy(to destination: URL, header: String) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data((header + "\n\n").utf8))
        var failure: Error?
        let complete = stream { chunk in
            do {
                try handle.write(contentsOf: Data(chunk))
                return true
            } catch {
                failure = error
                return false
            }
        }
        if let failure { throw failure }
        guard complete else { throw CocoaError(.fileReadUnknown) }
    }
}
