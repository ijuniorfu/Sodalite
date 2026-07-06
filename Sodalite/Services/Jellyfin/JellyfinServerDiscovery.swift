import Foundation
import Darwin

struct DiscoveredServer: Sendable, Identifiable, Equatable {
    let id: String
    let name: String
    let address: URL
}

protocol JellyfinServerDiscoveryProtocol: Sendable {
    func discover() -> AsyncStream<DiscoveredServer>
}

nonisolated final class JellyfinServerDiscovery: JellyfinServerDiscoveryProtocol {
    private let port: UInt16 = 7359
    private let query = "who is JellyfinServer?"
    private let scanDuration: TimeInterval = 4.0

    init() {}

    // Jellyfin's UDP discovery reply. PascalCase keys; EndpointAddress is ignored (null in practice).
    private struct Reply: Decodable {
        let address: String
        let id: String
        let name: String
        enum CodingKeys: String, CodingKey {
            case address = "Address"
            case id = "Id"
            case name = "Name"
        }
    }

    static func decodeReply(from data: Data) -> DiscoveredServer? {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
              !reply.id.isEmpty,
              !reply.address.isEmpty,
              let url = URL(string: reply.address)
        else { return nil }
        let name = reply.name.isEmpty ? "Jellyfin" : reply.name
        return DiscoveredServer(id: reply.id, name: name, address: url)
    }

    // Thread-safe cancel flag so leaving the screen stops the scan promptly.
    private final class ScanState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }

    func discover() -> AsyncStream<DiscoveredServer> {
        let port = self.port, query = self.query, duration = self.scanDuration
        let state = ScanState()
        return AsyncStream { continuation in
            continuation.onTermination = { _ in state.cancel() }
            DispatchQueue.global(qos: .utility).async {
                Self.run(port: port, query: query, duration: duration, state: state, continuation: continuation)
            }
        }
    }

    private static func run(
        port: UInt16,
        query: String,
        duration: TimeInterval,
        state: ScanState,
        continuation: AsyncStream<DiscoveredServer>.Continuation
    ) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { continuation.finish(); return }
        defer { close(fd); continuation.finish() }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        // 1s receive timeout so recvfrom unblocks to re-check the deadline / cancel flag.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = port.bigEndian
        dest.sin_addr.s_addr = inet_addr("255.255.255.255")

        let payload = Array(query.utf8)
        func broadcast() {
            withUnsafePointer(to: &dest) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = payload.withUnsafeBytes {
                        sendto(fd, $0.baseAddress, $0.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        let deadline = Date().addingTimeInterval(duration)
        var nextSend = Date.distantPast
        var seen = Set<String>()
        var buffer = [UInt8](repeating: 0, count: 2048)

        while Date() < deadline, !state.isCancelled {
            if Date() >= nextSend {
                broadcast()
                nextSend = Date().addingTimeInterval(1.0)
            }
            var from = sockaddr()
            var fromLen = socklen_t(MemoryLayout<sockaddr>.size)
            let n = buffer.withUnsafeMutableBytes {
                recvfrom(fd, $0.baseAddress, $0.count, 0, &from, &fromLen)
            }
            guard n > 0 else { continue } // timeout (EAGAIN) or error: loop re-checks deadline/cancel
            let reply = Data(buffer.prefix(n))
            if let server = decodeReply(from: reply), !seen.contains(server.id) {
                seen.insert(server.id)
                continuation.yield(server)
            }
        }
    }
}
