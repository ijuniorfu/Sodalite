import Foundation

/// Turns what somebody typed into a server URL field into the URL that gets stored.
///
/// Setup hands the raw text to a discovery service, which fans it out into scheme and port
/// candidates and keeps the one that answers, so "192.168.1.10" is a complete address there. The
/// URL editors parsed the same text strictly and probed it verbatim instead, which is why an
/// address that had just worked in setup came back as "enter valid URLs including the scheme" and
/// left the reporter permuting scheme and port by hand (Sodalite#83). Both go through discovery now.
///
/// The editors keep the one thing setup does not need: a slot can point at a network the device
/// cannot see from where it currently is (editing the internal URL over cellular), so an address
/// nobody answers is still savable as long as it stands on its own.
nonisolated enum ServerAddressResolution {
    enum Outcome: Sendable, Equatable {
        /// Field left empty: the slot is cleared on purpose.
        case empty
        /// Discovery reached a server. This is the candidate that answered, scheme and port included.
        case resolved(URL)
        /// Nothing answered, but the text is a URL on its own, so it can be stored as typed.
        case unreachable(URL)
        /// Nothing answered and the text is missing what it would take to store it unverified.
        case unresolved
    }

    /// How long discovery gets before the editor stops waiting on it.
    ///
    /// `DiscoveryProbeRace` budgets for a wizard whose only outcome is the address it finds: 10s per
    /// candidate, 25s for a race nobody has answered. Here a silent race has somewhere to go, the
    /// save-anyway dialog, and somebody is holding a disabled form while it runs, so the editor
    /// settles for a shorter look than setup does.
    static let probeBudget: Duration = .seconds(6)

    static func resolve(
        _ text: String,
        budget: Duration = probeBudget,
        discover: @escaping @Sendable (String) async -> URL?
    ) async -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if let answered = await answer(within: budget, { await discover(trimmed) }) {
            return .resolved(answered)
        }
        if let complete = completeURL(trimmed) { return .unreachable(complete) }
        return .unresolved
    }

    /// A URL carrying everything needed to store it without asking a server: a scheme this app
    /// speaks, and a host.
    static func completeURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        return url
    }

    private static func answer(
        within budget: Duration,
        _ work: @escaping @Sendable () async -> URL?
    ) async -> URL? {
        await withTaskGroup(of: URL?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

extension ServerAddressResolution {
    /// The discovery each backend already uses in setup, in the shape the editors ask for.
    static func jellyfin(_ service: any ServerDiscoveryServiceProtocol) -> @Sendable (String) async -> URL? {
        { input in
            guard case .success(let url, _) = await service.discoverServer(input: input) else { return nil }
            return url
        }
    }

    static func seerr(_ service: any SeerrServerDiscoveryServiceProtocol) -> @Sendable (String) async -> URL? {
        { input in
            guard case .success(let url, _) = await service.discoverServer(input: input) else { return nil }
            return url
        }
    }
}
