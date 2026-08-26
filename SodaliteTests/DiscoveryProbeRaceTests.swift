import Foundation
import Testing
@testable import Sodalite

/// Sodalite#82: a dropped SYN costs 61 s per candidate, so discovery must bound each probe and run
/// them together while still letting candidate order pick the winner.
@Suite("Discovery probe race")
struct DiscoveryProbeRaceTests {
    private let candidates = [
        URL(string: "https://seerr.example.com")!,
        URL(string: "http://seerr.example.com")!,
        URL(string: "http://seerr.example.com:5055")!,
    ]

    /// Answers `url` after `delay`; anything not listed hangs far past every bound in these tests.
    private func probe(
        answers: [URL: (delay: Duration, result: Result<String, APIError>)]
    ) -> @Sendable (URL) async -> Result<String, APIError> {
        { url in
            guard let answer = answers[url] else {
                try? await Task.sleep(for: .seconds(30))
                return .failure(.serverUnreachable)
            }
            try? await Task.sleep(for: answer.delay)
            return answer.result
        }
    }

    private func firstSuccess(_ verdicts: [Result<String, APIError>?]) -> String? {
        for verdict in verdicts {
            if case .success(let value) = verdict { return value }
        }
        return nil
    }

    @Test("slower higher-priority candidate still wins")
    func priorityBeatsSpeed() async {
        let verdicts = await DiscoveryProbeRace.run(
            candidates: candidates,
            timeout: .seconds(5),
            grace: .seconds(2),
            probe: probe(answers: [
                candidates[0]: (.milliseconds(200), .success("https")),
                candidates[1]: (.milliseconds(1), .success("http")),
            ])
        )
        #expect(firstSuccess(verdicts) == "https")
    }

    @Test("a hanging candidate cannot hold up a later success past the grace")
    func hangingCandidateYieldsAfterGrace() async {
        let start = ContinuousClock.now
        let verdicts = await DiscoveryProbeRace.run(
            candidates: candidates,
            timeout: .seconds(20),
            grace: .milliseconds(200),
            probe: probe(answers: [
                candidates[2]: (.milliseconds(1), .success("port5055")),
            ])
        )
        let elapsed = start.duration(to: .now)

        #expect(firstSuccess(verdicts) == "port5055")
        // The hang is 30 s and the per-candidate timeout 20 s; only the grace can end this quickly.
        #expect(elapsed < .seconds(5))
        #expect(verdicts[0] == nil)
    }

    @Test("a failure ahead of the winner does not wait for the grace")
    func settledFailuresReturnImmediately() async {
        let start = ContinuousClock.now
        let verdicts = await DiscoveryProbeRace.run(
            candidates: candidates,
            timeout: .seconds(20),
            grace: .seconds(20),
            probe: probe(answers: [
                candidates[0]: (.milliseconds(1), .failure(.serverUnreachable)),
                candidates[1]: (.milliseconds(1), .failure(.serverUnreachable)),
                candidates[2]: (.milliseconds(1), .success("port5055")),
            ])
        )
        let elapsed = start.duration(to: .now)

        #expect(firstSuccess(verdicts) == "port5055")
        #expect(elapsed < .seconds(5))
    }

    @Test("every candidate is capped by the timeout")
    func allDeadEndsAtTheTimeout() async {
        let start = ContinuousClock.now
        let verdicts = await DiscoveryProbeRace.run(
            candidates: candidates,
            timeout: .milliseconds(300),
            extendedTimeout: .milliseconds(600),
            grace: .seconds(1),
            probe: probe(answers: [:])
        )
        let elapsed = start.duration(to: .now)

        #expect(firstSuccess(verdicts) == nil)
        #expect(verdicts.allSatisfy { $0 != nil })
        for verdict in verdicts {
            guard case .failure(let error) = verdict else { continue }
            #expect(error.isTimeout)
        }
        // Sequentially this would be 3 x 300 ms; concurrently it is one.
        #expect(elapsed < .seconds(5))
    }

    @Test("candidate order is preserved in the verdicts")
    func verdictsFollowCandidateOrder() async {
        let verdicts = await DiscoveryProbeRace.run(
            candidates: candidates,
            timeout: .seconds(5),
            grace: .milliseconds(200),
            probe: probe(answers: [
                candidates[0]: (.milliseconds(1), .failure(.serverUnreachable)),
                candidates[1]: (.milliseconds(1), .success("http")),
                candidates[2]: (.milliseconds(1), .success("port5055")),
            ])
        )
        #expect(verdicts.count == 3)
        if case .failure = verdicts[0] {} else { Issue.record("candidate 0 must report its failure") }
        #expect(firstSuccess(verdicts) == "http")
    }

    /// Sodalite#82, round 2: the cap is a verdict about a candidate nobody has heard from, and a
    /// race where NOT ONE candidate has answered has no evidence for it. The reporter's Jellyseerr
    /// answered in 0.4 s from a fresh launch and was declared unreachable a few seconds later, with
    /// all four candidates cancelled at the same 10 s wall.
    @Test("nothing answered by the cap buys the extended window")
    func silentRaceGetsTheExtendedWindow() async {
        let verdicts = await DiscoveryProbeRace.run(
            candidates: candidates,
            timeout: .milliseconds(200),
            extendedTimeout: .seconds(3),
            grace: .milliseconds(200),
            probe: probe(answers: [
                candidates[2]: (.milliseconds(700), .success("port5055")),
            ])
        )
        #expect(firstSuccess(verdicts) == "port5055")
    }

    /// The other half of that rule: one candidate answering is the evidence the cap needs, so the
    /// silent ones are capped on time instead of stretching the spinner to the extended window.
    @Test("one answer holds the silent candidates to the short cap")
    func oneAnswerKeepsTheShortCap() async {
        let start = ContinuousClock.now
        let verdicts = await DiscoveryProbeRace.run(
            candidates: candidates,
            timeout: .milliseconds(300),
            extendedTimeout: .seconds(10),
            grace: .milliseconds(200),
            probe: probe(answers: [
                candidates[1]: (.milliseconds(1), .failure(.serverUnreachable)),
            ])
        )
        let elapsed = start.duration(to: .now)

        #expect(firstSuccess(verdicts) == nil)
        #expect(elapsed < .seconds(3))
        #expect(verdicts.allSatisfy { $0 != nil })
    }

    /// What the whole race reports back. A cancelled-at-the-cap candidate is our own decision to
    /// stop waiting, so it must not reach the viewer as "Server unreachable".
    @Test("a race of capped candidates reports a timeout, not an unreachable server")
    func aggregateOfCappedCandidatesIsATimeout() {
        let verdicts: [Result<String, APIError>?] = [.failure(.timeout), .failure(.timeout), nil]
        #expect(DiscoveryProbeRace.aggregateError(verdicts).isTimeout)
    }

    @Test("a candidate that answered the wrong protocol outranks a timeout")
    func aggregatePrefersAProtocolAnswer() {
        let verdicts: [Result<String, APIError>?] = [
            .failure(.timeout),
            .failure(.httpError(statusCode: 404, data: Data())),
        ]
        if case .httpError(let status, _) = DiscoveryProbeRace.aggregateError(verdicts) {
            #expect(status == 404)
        } else {
            Issue.record("a candidate that answered must outrank one that was cancelled")
        }
    }

    @Test("dead transports still report an unreachable server")
    func aggregateOfDeadTransportsStaysUnreachable() {
        let verdicts: [Result<String, APIError>?] = [.failure(.serverUnreachable), .failure(.serverUnreachable)]
        if case .serverUnreachable = DiscoveryProbeRace.aggregateError(verdicts) {} else {
            Issue.record("nothing here was cancelled by us, so the address is the story")
        }
    }

    @Test("no candidates yields no verdicts")
    func emptyCandidates() async {
        let verdicts = await DiscoveryProbeRace.run(
            candidates: [],
            probe: { _ in .success("never") }
        )
        #expect(verdicts.isEmpty)
    }
}

private extension APIError {
    var isTimeout: Bool {
        if case .timeout = self { return true }
        return false
    }
}
