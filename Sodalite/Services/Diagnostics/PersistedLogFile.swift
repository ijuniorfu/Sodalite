import Foundation

/// The file sink's file (AE#597), frozen at the moment someone asked to take it off the device.
///
/// Holds an open descriptor and the length it had then, not a path. The sink keeps appending while a
/// reporter downloads, and arming it on a full file deletes and recreates it; a descriptor keeps the
/// bytes that were there readable through both, and the length keeps what is handed over from moving,
/// the same rule `LogExportSession` applies to the buffer.
///
/// Read with `pread`, so concurrent requests for it never share a file offset.
nonisolated final class PersistedLogFile: Sendable {
    let length: Int
    private let fd: Int32

    /// Nil when there is nothing worth offering: no file, or one the sink never wrote a line to.
    init?(url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else {
            close(fd)
            return nil
        }
        self.fd = fd
        self.length = Int(info.st_size)
    }

    deinit {
        close(fd)
    }

    /// Hands the frozen bytes to `sink` in bounded chunks, so a 32 MB file never sits in memory whole.
    /// Stops early when `sink` returns false (the peer went away). Returns whether every byte went out.
    @discardableResult
    func stream(chunkSize: Int = 64 * 1024, into sink: (UnsafeRawBufferPointer) -> Bool) -> Bool {
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var offset = 0
        while offset < length {
            let wanted = min(chunkSize, length - offset)
            let read = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, wanted, off_t(offset)) }
            guard read > 0 else { return false }
            let delivered = buffer.withUnsafeBytes { sink(UnsafeRawBufferPointer(rebasing: $0[0 ..< read])) }
            guard delivered else { return false }
            offset += read
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
