import Foundation

/// Probes server-discovery candidates concurrently instead of one after another.
///
/// A bare address expands into up to four scheme/port candidates and at most one of them can be
/// right. The wrong ones either refuse instantly (nothing listening) or hang until the request
/// times out, which is what a home router does from the outside: it DROPs the SYN rather than
/// refusing it. Measured on macOS 26 against a blackholed RFC1918 host, one such candidate costs
/// **61.0 s** with URLSession's default request timeout, so the old sequential loop could sit on a
/// spinner for minutes before reaching the candidate that works (Sodalite#82).
///
/// Two bounds replace that: every candidate carries its own `timeout`, and all of them start at
/// once. Order still decides the winner, so https is never traded for http just because http
/// answered first; `grace` only caps how long a still-pending higher-priority candidate may hold
/// up a lower-priority one that already succeeded.
///
/// The parallel start does mean the plain-http candidates now go out even when https works. They
/// carry no credentials (both backends expose an unauthenticated status endpoint) and they can
/// never win a race a higher-priority candidate also finishes.
nonisolated enum DiscoveryProbeRace {
    /// Per-candidate ceiling: far above a healthy status round trip on slow cellular, far below
    /// the 61 s a dropped SYN costs by default.
    static let candidateTimeout: Duration = .seconds(10)

    /// How long a pending higher-priority candidate may delay an already-successful one.
    static let priorityGrace: Duration = .seconds(2)

    /// Runs every candidate at once and returns their verdicts in candidate order, so the caller
    /// keeps picking the first success exactly as a sequential loop would. A `nil` entry marks a
    /// candidate that was still in flight when the race ended, which only happens once a
    /// higher-priority winner is already settled.
    static func run<Success: Sendable>(
        candidates: [URL],
        timeout: Duration = candidateTimeout,
        grace: Duration = priorityGrace,
        probe: @escaping @Sendable (URL) async -> Result<Success, APIError>
    ) async -> [Result<Success, APIError>?] {
        guard !candidates.isEmpty else { return [] }

        return await withTaskGroup(of: ProbeEvent<Success>.self) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask {
                    .verdict(index, await bounded(url, timeout: timeout, probe: probe))
                }
            }

            var verdicts = [Result<Success, APIError>?](repeating: nil, count: candidates.count)
            var winner: Int?
            var graceRunning = false

            while let event = await group.next() {
                switch event {
                case .graceExpired:
                    // Whatever still outranks the winner has had its window; stop waiting on it.
                    group.cancelAll()
                    return verdicts

                case .verdict(let index, let result):
                    verdicts[index] = result
                    if case .success = result, winner.map({ index < $0 }) ?? true {
                        winner = index
                    }
                    guard let leader = winner else { continue }
                    // Every candidate ahead of the winner has answered, so nothing better can land.
                    if verdicts[..<leader].allSatisfy({ $0 != nil }) {
                        group.cancelAll()
                        return verdicts
                    }
                    if !graceRunning {
                        graceRunning = true
                        group.addTask {
                            try? await Task.sleep(for: grace)
                            return .graceExpired
                        }
                    }
                }
            }

            return verdicts
        }
    }

    /// One candidate, capped at `timeout`. The cap lives here rather than on the shared
    /// `HTTPClient` session because it is discovery-specific: a probe against a guessed address is
    /// allowed to be declared dead long before a real API call would be.
    private static func bounded<Success: Sendable>(
        _ url: URL,
        timeout: Duration,
        probe: @escaping @Sendable (URL) async -> Result<Success, APIError>
    ) async -> Result<Success, APIError> {
        await withTaskGroup(of: Result<Success, APIError>?.self) { group in
            group.addTask { await probe(url) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failure(.timeout)
        }
    }

    /// Everything a probe can throw, folded into the vocabulary the candidate loop classifies by.
    /// A cancelled probe (caller left the screen, or a settled winner ended the race) must not be
    /// mistaken for a protocol answer, so it lands on `.serverUnreachable` like a dead host.
    static func normalized(_ error: any Error) -> APIError {
        switch error {
        case is CancellationError:
            return .serverUnreachable
        case let error as DecodingError:
            return .decodingError(error)
        case let error as APIError:
            return error
        default:
            return .networkError(error)
        }
    }

    /// Short outcome word for a diagnostic line. Deliberately not `errorDescription`: that one is
    /// localized user copy, and a log line a reporter pastes into an issue has to read the same in
    /// every language.
    static func logLabel(for error: APIError) -> String {
        switch error {
        case .httpError(let statusCode, _): "HTTP \(statusCode)"
        case .unauthorized: "HTTP 401"
        case .decodingError: "wrong service"
        case .timeout: "timed out"
        case .serverUnreachable: "unreachable"
        case .invalidResponse: "invalid response"
        case .invalidURL: "invalid URL"
        case .networkError(let underlying): "network error (\((underlying as NSError).code))"
        }
    }

    /// "1.4s" since `start`, for the diagnostic lines both discovery services emit.
    static func elapsedText(since start: ContinuousClock.Instant) -> String {
        let components = start.duration(to: .now).components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return String(format: "%.1fs", seconds)
    }
}

private nonisolated enum ProbeEvent<Success: Sendable>: Sendable {
    case verdict(Int, Result<Success, APIError>)
    case graceExpired
}
