import Testing
import Foundation
import AetherEngine
@testable import Sodalite

/// The half the stubbed store tests cannot reach: the engine pass itself, run with the budgets this
/// app hands it (AE#579).
///
/// Two 64x64 HEVC Main 10 PQ / BT.2020 fixtures from the engine's own suite, ~1 KB each, identical
/// except for one thing: the positive one precedes each access unit with an ITU-T T.35 prefix SEI
/// carrying a valid ST 2094-40 payload. The negative one is the load-bearing half, a pass that
/// answered yes to everything would satisfy the positive test on its own.
@Suite("HDR10+ probe: the real engine pass, with this app's budgets")
struct HDR10PlusProbeEngineTests {

    static let hdr10PlusBase64 = """
    AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAAwG1kYXQAAABFTgEEQLUAPAAB
    BABCYloAhNA+gB1MC7gkCA+gKB9AUC7gyE4hkH0CWLuC0PoC+RlDGTiAZE+hLCRkMhLGQfSWK8yD
    hACAAAAADigBr3jrrvv//FtlXy08AAAARU4BBEC1ADwAAQQAQmJaAITQPoAdTAu4JAgPoCgfQFAu
    4MhOIZB9Ali7gtD6AvkZQxk4gGRPoSwkZDISxkH0livMg4QAgAAAABAoAa8J4CQEyH//J2Eew0j8
    AAADw21vb3YAAABsbXZoZAAAAAAAAAAAAAAAAAAAA+gAAADIAAEAAAEAAAAAAAAAAAAAAAABAAAA
    AAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    AAIAAALtdHJhawAAAFx0a2hkAAAAAwAAAAAAAAAAAAAAAQAAAAAAAADIAAAAAAAAAAAAAAAAAAAA
    AAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAABAAAAAQAAAAAAAJGVkdHMAAAAc
    ZWxzdAAAAAAAAAABAAAAyAAAAAAAAQAAAAACZW1kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAAST4AA
    A6mAVcQAAAAAAC1oZGxyAAAAAAAAAAB2aWRlAAAAAAAAAAAAAAAAVmlkZW9IYW5kbGVyAAAAAhBt
    aW5mAAAAFHZtaGQAAAABAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAA
    AAEAAAHQc3RibAAAAWRzdHNkAAAAAAAAAAEAAAFUaHZjMQAAAAAAAAABAAAAAAAAAAAAAAAAAAAA
    AABAAEAASAAAAEgAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABj//wAA
    AMdodmNDAQQIAAAAnagAAAAAHvAA/P36+gAADwOgAAIAF0ABDAH//wQIAAADAJ2oAAADAAAeugJA
    ABdAAQwB//8ECAAAAwCdqAAAAwAAHroCQKEAAgArQgEBBAgAAAMAnagAAAMAAB6gIIEE2W6kkyvA
    WoSIBIIAAAMAAgAAAwAUEAArQgEBBAgAAAMAnagAAAMAAB6gIIEE2W6kkyvAWoSIBIIAAAMAAgAA
    AwAUEKIAAgAHRAHBcrAiQAAIRAHBcrAiQAAAAAATY29scm5jbHgACQAQAAkAAAAAEHBhc3AAAAAB
    AAAAAQAAABRidHJ0AAAAAAAAHMAAABzAAAAAGHN0dHMAAAAAAAAAAQAAAAIAAdTAAAAAHHN0c2MA
    AAAAAAAAAQAAAAEAAAACAAAAAQAAABxzdHN6AAAAAAAAAAAAAAACAAAAWwAAAF0AAAAUc3RjbwAA
    AAAAAAABAAAALAAAAGJ1ZHRhAAAAWm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAA
    AAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAAAQAAAABMYXZmNjIuMTIuMTAx
    """

    static let hdr10Base64 = """
    AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAALm1kYXQAAAAOKAGveOuu+//8
    W2VfLTwAAAAQKAGvCeAkBMh//ydhHsNI/AAAA8Ntb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPo
    AAAAyAABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAA
    AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAC7XRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAA
    AAEAAAAAAAAAyAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAA
    AEAAAAAAQAAAAEAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAMgAAAAAAAEAAAAAAmVtZGlh
    AAAAIG1kaGQAAAAAAAAAAAAAAAAAEk+AAAOpgFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAA
    AAAAAAAAAFZpZGVvSGFuZGxlcgAAAAIQbWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYA
    AAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAB0HN0YmwAAAFkc3RzZAAAAAAAAAABAAABVGh2
    YzEAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAQABAAEgAAABIAAAAAAAAAAEAAAAAAAAAAAAAAAAA
    AAAAAAAAAAAAAAAAAAAAAAAAAAAY//8AAADHaHZjQwEECAAAAJ2oAAAAAB7wAPz9+voAAA8DoAAC
    ABdAAQwB//8ECAAAAwCdqAAAAwAAHroCQAAXQAEMAf//BAgAAAMAnagAAAMAAB66AkChAAIAK0IB
    AQQIAAADAJ2oAAADAAAeoCCBBNlupJMrwFqEiASCAAADAAIAAAMAFBAAK0IBAQQIAAADAJ2oAAAD
    AAAeoCCBBNlupJMrwFqEiASCAAADAAIAAAMAFBCiAAIAB0QBwXKwIkAACEQBwXKwIkAAAAAAE2Nv
    bHJuY2x4AAkAEAAJAAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAAAXwAAAF8AAAABhzdHRz
    AAAAAAAAAAEAAAACAAHUwAAAABxzdHNjAAAAAAAAAAEAAAABAAAAAgAAAAEAAAAcc3RzegAAAAAA
    AAAAAAAAAgAAABIAAAAUAAAAFHN0Y28AAAAAAAAAAQAAACwAAABidWR0YQAAAFptZXRhAAAAAAAA
    ACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAAC1pbHN0AAAAJal0b28AAAAdZGF0YQAA
    AAEAAAAATGF2ZjYyLjEyLjEwMQ==
    """

    private static func fixture(_ base64: String, _ name: String) throws -> URL {
        let data = try #require(Data(base64Encoded: base64.replacingOccurrences(of: "\n", with: ""),
                                     options: .ignoreUnknownCharacters))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sodalite-hdr10plus-\(name)-\(UUID().uuidString).mp4")
        try data.write(to: url)
        return url
    }

    @Test("the app's own probe closure confirms a file that carries ST 2094-40")
    func confirmsCarryingFile() throws {
        let url = try Self.fixture(Self.hdr10PlusBase64, "plus")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try HDR10PlusProbeStore.engineProbe(url, ProbeCancellation()))
    }

    @Test("the same closure says no to the same encode without the SEI")
    func refusesPlainHDR10() throws {
        let url = try Self.fixture(Self.hdr10Base64, "plain")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try !HDR10PlusProbeStore.engineProbe(url, ProbeCancellation()))
    }

    @Test("a cancelled probe stops instead of finishing the read")
    func cancellationStopsTheProbe() throws {
        let url = try Self.fixture(Self.hdr10PlusBase64, "cancelled")
        defer { try? FileManager.default.removeItem(at: url) }
        let cancellation = ProbeCancellation()
        cancellation.cancel()

        #expect(throws: (any Error).self) {
            try HDR10PlusProbeStore.engineProbe(url, cancellation)
        }
    }

    /// The budgets are the part of this that is a decision rather than a call, so they are pinned.
    ///
    /// `maxPacketBytes` is the one that would fail silently: a packet larger than the budget is
    /// rejected BEFORE inspection, so the 2 MiB default would refuse a UHD HEVC keyframe, which runs
    /// to several MB, and report "no HDR10+" for exactly the material this feature is for. The
    /// whole-probe input budget sits above the detail pass's own 16 MiB for the same reason: the
    /// pass should stop at its cap, not the probe throw before it gets there.
    @Test("the whole-probe budget cannot cut the detail pass short")
    func budgetsLeaveRoomForThePass() {
        let pass = HDR10PlusDetectionOptions()
        #expect(HDR10PlusProbeStore.limits.maxPacketBytes >= 16 * 1024 * 1024)
        #expect(HDR10PlusProbeStore.limits.maxInputBytes > pass.maxBytes)
        #expect(HDR10PlusProbeStore.limits.timeBudget > pass.timeBudget)
    }
}
