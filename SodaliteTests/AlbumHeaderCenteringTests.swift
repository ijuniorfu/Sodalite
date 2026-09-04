import Testing
import Foundation
@testable import Sodalite

/// Sodalite#109: on a track-less album (a podcast Jellyfin models as one audio item, or genuinely
/// empty metadata) nothing renders below the header, and the leading-pinned header left the cover
/// against the left edge with the rest of the page empty.
///
/// The header recenters on exactly one state, and the hard part is which one. Nothing renders below
/// the header while the album is still loading either (the ProgressView lives inside the header,
/// and the tracklist is empty until the songs arrive), and nothing renders on the frame before the
/// task even starts. Reacting to either of those would make the common album, the one WITH tracks,
/// start centered and jump into place. So the trigger is an answered load, not an absent tracklist.
@MainActor
struct AlbumHeaderCenteringTests {

    private struct Boom: Error {}

    private func track(_ id: String) throws -> JellyfinItem {
        try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"\#(id)","Name":"Track \#(id)","Type":"Audio"}"#.utf8)
        )
    }

    // MARK: - The one state that centers

    @Test("An answered load with no tracks is the empty album")
    func anAnsweredEmptyAlbumIsConfirmed() async {
        let viewModel = AlbumDetailViewModel()
        await viewModel.load(albumID: "alb", service: MusicAlbumLoadTests.MusicSpy(), userID: "u")

        #expect(viewModel.isConfirmedEmpty)
    }

    // MARK: - The states that must not center

    /// The frame before `.task` runs: songs are empty and nothing is loading, which is the empty
    /// album's exact shape minus the answer. Reading it as empty would center every album for one
    /// frame.
    @Test("Before the first load the header stays pinned")
    func nothingIsConfirmedBeforeTheFirstLoad() {
        #expect(AlbumDetailViewModel().isConfirmedEmpty == false)
    }

    @Test("An album with tracks never centers")
    func tracksKeepTheHeaderPinned() async throws {
        let spy = MusicAlbumLoadTests.MusicSpy()
        spy.songs = [try track("t1")]

        let viewModel = AlbumDetailViewModel()
        await viewModel.load(albumID: "alb", service: spy, userID: "u")

        #expect(viewModel.isConfirmedEmpty == false)
    }

    /// A failed fetch renders an error and a Retry button below the header, so there IS content
    /// below and the pinned layout is still the right one. Same rule as Sodalite#88.
    @Test("A failed fetch keeps the pinned layout, its error is content below")
    func aFailedFetchKeepsThePinnedLayout() async {
        let spy = MusicAlbumLoadTests.MusicSpy()
        spy.error = APIError.timeout

        let viewModel = AlbumDetailViewModel()
        await viewModel.load(albumID: "alb", service: spy, userID: "u")

        #expect(viewModel.displayedError != nil)
        #expect(viewModel.isConfirmedEmpty == false)
    }

    /// Without an active user nothing was asked, so nothing was answered.
    @Test("An unasked album is not an empty one")
    func withoutAUserNothingIsConfirmed() async {
        let viewModel = AlbumDetailViewModel()
        await viewModel.load(albumID: "alb", service: MusicAlbumLoadTests.MusicSpy(), userID: nil)

        #expect(viewModel.isConfirmedEmpty == false)
    }

    /// "A cancelled reload is not an outcome" already governs errorMessage; it governs the layout
    /// for the same reason. A cancelled load leaves the album undetermined, not empty.
    @Test("A cancelled load is not an answer")
    func aCancelledLoadIsNotAnAnswer() async {
        let spy = MusicAlbumLoadTests.MusicSpy()
        spy.error = CancellationError()

        let viewModel = AlbumDetailViewModel()
        await viewModel.load(albumID: "alb", service: spy, userID: "u")

        #expect(viewModel.isConfirmedEmpty == false)
    }

    // MARK: - The in-flight window

    /// The reported trap: nothing renders below the header during the load either. A test built on
    /// "is there content below" would hold the pinned layout through the load and then snap. This
    /// pins that the state is read from the answer, and that the switch happens once, at the end.
    @Test("Mid-load the header is not centered, and it becomes centered when the load answers")
    func theHeaderDoesNotCenterMidLoad() async {
        let spy = GatedMusicSpy()
        let viewModel = AlbumDetailViewModel()

        let load = Task { await viewModel.load(albumID: "alb", service: spy, userID: "u") }
        while !viewModel.isLoading { await Task.yield() }

        #expect(viewModel.songs.isEmpty)
        #expect(viewModel.isConfirmedEmpty == false)

        await spy.gate.release()
        await load.value

        #expect(viewModel.isConfirmedEmpty)
    }

    // MARK: - Dead controls

    /// The coordinator refuses an empty queue, so on a track-less album Play and Shuffle were
    /// controls that could not do anything. They are drawn only when there is something to play.
    @Test("A track-less album offers no Play button")
    func anEmptyAlbumHidesItsTransport() async {
        let viewModel = AlbumDetailViewModel()
        await viewModel.load(albumID: "alb", service: MusicAlbumLoadTests.MusicSpy(), userID: "u")

        #expect(viewModel.isConfirmedEmpty)
        #expect(viewModel.canPlay == false)
    }

    /// A failed fetch leaves nothing to play either, and hiding the two dead buttons hands tvOS
    /// focus to the Retry button below, which is the control that can actually help.
    @Test("A failed fetch offers no Play button either")
    func aFailedFetchHidesItsTransport() async {
        let spy = MusicAlbumLoadTests.MusicSpy()
        spy.error = APIError.timeout

        let viewModel = AlbumDetailViewModel()
        await viewModel.load(albumID: "alb", service: spy, userID: "u")

        #expect(viewModel.displayedError != nil)
        #expect(viewModel.canPlay == false)
    }

    @Test("An album with tracks keeps its transport")
    func tracksKeepTheTransport() async throws {
        let spy = MusicAlbumLoadTests.MusicSpy()
        spy.songs = [try track("t1")]

        let viewModel = AlbumDetailViewModel()
        await viewModel.load(albumID: "alb", service: spy, userID: "u")

        #expect(viewModel.canPlay)
    }

    /// Hiding the dead controls left the page saying nothing at all about itself, so the empty
    /// album names its state where the buttons were.
    @Test("The empty album says so, in all 26 locales")
    func theEmptyAlbumNamesItsState() throws {
        let view = try sourceFile("Sodalite/Features/Music/AlbumDetailView.swift")
        #expect(view.contains("} else if viewModel.isConfirmedEmpty {"))
        #expect(view.contains(#"Text("album.detail.empty")"#))

        let catalog = try JSONSerialization.jsonObject(
            with: Data(contentsOf: repositoryFile("Sodalite/Localizable.xcstrings"))
        ) as? [String: Any]
        let strings = catalog?["strings"] as? [String: Any]
        let entry = try #require(strings?["album.detail.empty"] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])

        #expect(localizations.count == 26)
        for (locale, value) in localizations {
            let unit = (value as? [String: Any])?["stringUnit"] as? [String: Any]
            #expect(unit?["state"] as? String == "translated", "\(locale) is not translated")
            #expect((unit?["value"] as? String)?.isEmpty == false, "\(locale) is empty")
        }
    }

    // MARK: - Structure

    /// Centering has to move the title block's OWN alignment. `.multilineTextAlignment` alone
    /// centers each line inside its own width and leaves the lines ragged against each other, so
    /// the block takes a `HorizontalAlignment` and applies both.
    @Test("The title block centers itself, not just its wrapped lines")
    func theTitleBlockTakesAnAlignment() throws {
        let source = try sourceFile("Sodalite/Features/Music/AlbumDetailView.swift")

        #expect(source.contains("private func titleBlock(alignment: HorizontalAlignment)"))
        #expect(source.contains("VStack(alignment: alignment, spacing: 6)"))
        #expect(source.contains(".multilineTextAlignment(alignment == .center ? .center : .leading)"))
    }

    /// The switch is a layout swap over one child set, not two branches. Two branches give the
    /// children new identities, which drops tvOS focus off the Play button at the moment the load
    /// resolves and turns the move into a pop instead of an animation.
    @Test("The header switches layout, it does not switch branches")
    func theHeaderKeepsItsChildrenAcrossTheSwitch() throws {
        let source = try sourceFile("Sodalite/Features/Music/AlbumDetailView.swift")

        #expect(source.contains("AnyLayout(VStackLayout(alignment: .center, spacing: 24))"))
        #expect(source.contains("AnyLayout(HStackLayout(alignment: .top, spacing: 48))"))
    }

    /// The two halves of one rule, in two files: the coordinator refuses an empty queue, and the
    /// header does not offer a button that would hit that refusal. Either half alone brings the dead
    /// control back.
    @Test("The button only exists where the coordinator would not refuse")
    func theTransportGateMatchesTheCoordinatorGuard() throws {
        let view = try sourceFile("Sodalite/Features/Music/AlbumDetailView.swift")
        let coordinator = try sourceFile("Sodalite/Features/Music/MusicPlaybackCoordinator.swift")

        #expect(view.contains("} else if viewModel.canPlay {"))
        #expect(coordinator.contains("guard !items.isEmpty else { return }"))
    }

    private func repositoryFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        try String(contentsOf: repositoryFile(relativePath), encoding: .utf8)
    }
}


// MARK: - Gated spy

/// Holds a load open so the in-flight window is observable. Release first, wait second, so a waiter
/// that arrives after the release still returns instead of parking forever.
private actor Gate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private final class GatedMusicSpy: JellyfinMusicServiceProtocol, @unchecked Sendable {
    let gate = Gate()
    var songs: [JellyfinItem] = []

    func getSongs(userID: String, albumID: String) async throws -> [JellyfinItem] {
        await gate.wait()
        return songs
    }

    func getAlbums(userID: String) async throws -> [JellyfinItem] { [] }
    func getAllSongs(userID: String, limit: Int) async throws -> [JellyfinItem] { [] }
    func hasMusicLibrary(userID: String) async throws -> Bool { true }
}
