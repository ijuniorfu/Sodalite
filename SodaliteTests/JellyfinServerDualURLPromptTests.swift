import Foundation
import Testing
@testable import Sodalite

@Suite("JellyfinServer dual-URL prompt helpers")
struct JellyfinServerDualURLPromptTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test("internal-only server offers the external slot")
    func internalOnly() {
        let s = JellyfinServer(id: "a", name: "A", internalURL: url("http://10.0.0.2:8096"), externalURL: nil, version: nil)
        #expect(s.emptyURLSlot == .external)
    }

    @Test("external-only server offers the internal slot")
    func externalOnly() {
        let s = JellyfinServer(id: "a", name: "A", internalURL: nil, externalURL: url("https://jf.example.com"), version: nil)
        #expect(s.emptyURLSlot == .internal)
    }

    @Test("dual-URL server offers nothing")
    func both() {
        let s = JellyfinServer(id: "a", name: "A", internalURL: url("http://10.0.0.2:8096"), externalURL: url("https://jf.example.com"), version: nil)
        #expect(s.emptyURLSlot == nil)
    }

    @Test("filling external keeps the existing internal")
    func fillExternal() {
        let s = JellyfinServer(id: "a", name: "A", internalURL: url("http://10.0.0.2:8096"), externalURL: nil, version: nil)
        let merged = s.urls(filling: .external, with: url("https://jf.example.com"))
        #expect(merged.internal == url("http://10.0.0.2:8096"))
        #expect(merged.external == url("https://jf.example.com"))
    }

    @Test("filling internal keeps the existing external")
    func fillInternal() {
        let s = JellyfinServer(id: "a", name: "A", internalURL: nil, externalURL: url("https://jf.example.com"), version: nil)
        let merged = s.urls(filling: .internal, with: url("http://10.0.0.2:8096"))
        #expect(merged.internal == url("http://10.0.0.2:8096"))
        #expect(merged.external == url("https://jf.example.com"))
    }
}
