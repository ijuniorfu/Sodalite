import Testing
import Foundation
@testable import Sodalite

/// Channel search runs client-side because Jellyfin cannot filter channels by name. That makes the
/// matcher ours to get right: a German user typing "buro" expects "Büro TV", and typing a number
/// expects the channel at that position, not every channel containing the digit.
@MainActor
struct GuideChannelSearchTests {

    private func channel(_ name: String, number: String? = nil) -> JellyfinChannel {
        JellyfinChannel(id: name, name: name, channelNumber: number,
                        imageTags: nil, currentProgram: nil, userData: nil)
    }

    @Test("an empty query matches everything")
    func emptyQuery() {
        #expect(GuideViewModel.matches(channel: channel("ARD"), query: ""))
        #expect(GuideViewModel.matches(channel: channel("ARD"), query: "   "))
    }

    @Test("name matching ignores case")
    func caseInsensitive() {
        #expect(GuideViewModel.matches(channel: channel("Das Erste"), query: "erste"))
        #expect(GuideViewModel.matches(channel: channel("Das Erste"), query: "DAS"))
    }

    @Test("name matching ignores diacritics in both directions")
    func diacriticInsensitive() {
        #expect(GuideViewModel.matches(channel: channel("Büro TV"), query: "buro"))
        #expect(GuideViewModel.matches(channel: channel("Buro TV"), query: "büro"))
    }

    @Test("substring matching finds a channel by any part of its name")
    func substring() {
        #expect(GuideViewModel.matches(channel: channel("ZDF neo"), query: "neo"))
        #expect(!GuideViewModel.matches(channel: channel("ZDF neo"), query: "neon"))
    }

    @Test("channel numbers match by prefix, not by containment")
    func numberPrefix() {
        let three = channel("RTL", number: "3")
        let thirteen = channel("Sport1", number: "13")
        #expect(GuideViewModel.matches(channel: three, query: "3"))
        #expect(GuideViewModel.matches(channel: thirteen, query: "1"))
        // "3" must not drag in channel 13, or typing a number is useless on a large list.
        #expect(!GuideViewModel.matches(channel: thirteen, query: "3"))
    }

    @Test("a channel without a number is still searchable by name")
    func missingNumber() {
        #expect(GuideViewModel.matches(channel: channel("Arte"), query: "art"))
        #expect(!GuideViewModel.matches(channel: channel("Arte"), query: "7"))
    }

    @Test("a query of only whitespace does not filter anything out")
    func whitespaceQuery() {
        let all = [channel("ARD"), channel("ZDF"), channel("RTL")]
        #expect(all.allSatisfy { GuideViewModel.matches(channel: $0, query: "  \n ") })
    }
}
