@testable import Lume
import Testing

/// Grouping cases from a real 9,899-channel provider list (2026-10).
struct LiveChannelVariantsTests {
    private func member(_ id: String, _ name: String, category: String = "uk", num: Int = 0, hidden: Bool = false)
        -> LiveChannelVariants.Member
    {
        LiveChannelVariants.Member(id: id, name: name, categoryID: category, num: num, isHidden: hidden)
    }

    @Test func `a channel's qualities fold under the first one listed`() {
        let names = ["Sky Sports Main Event UHD", "Sky Sports Main Event FHD 50FPS", "Sky Sports Main Event FHD",
                     "Sky Sports Main Event HD", "Sky Sports Main Event SD"]
        let members = names.enumerated().map { member("\($0.offset)", $0.element, num: $0.offset) }
        let result = LiveChannelVariants.assignments(for: members)
        #expect(result.count == 5)
        #expect(Set(result.values.map(\.key)) == ["sky sports main event"])
        #expect(result.filter { !$0.value.isFollower }.map(\.key) == ["0"])
        #expect(result["0"]?.qualities == "UHD · FHD · HD · SD")
    }

    @Test func `a channel with one quality is left alone`() {
        let result = LiveChannelVariants.assignments(for: [member("a", "Channel 4 FHD"), member("b", "Channel 5 FHD")])
        #expect(result.isEmpty)
    }

    @Test func `repeated names are separate listings, not qualities`() {
        let events = (0 ..< 3).map { member("e\($0)", "US|NFHS LIVE - Newark", num: $0) }
        let cased = [member("p", "Brazzers"), member("q", "BRAZZERS")]
        #expect(LiveChannelVariants.assignments(for: events + cased).isEmpty)
    }

    @Test func `regions and timeshifts stay separate channels`() {
        let result = LiveChannelVariants.assignments(for: [
            member("uk", "PREMIER SPORTS 1 FHD (UK)", num: 1), member("ukhd", "PREMIER SPORTS 1 HD (UK)", num: 2),
            member("ie", "PREMIER SPORTS 1 FHD (IRE)", num: 3),
            member("e4", "E4 HD", num: 4), member("e4p1", "E4 +1", num: 5)
        ])
        #expect(Set(result.keys) == ["uk", "ukhd"])
    }

    @Test func `each category keeps its own row, and the qualities span them`() {
        let result = LiveChannelVariants.assignments(for: [
            member("f1fhd", "Sky Sports F1 FHD", category: "sports", num: 1),
            member("f1hd", "Sky Sports F1 HD", category: "sports", num: 2),
            member("f1uhd", "Sky Sports F1 UHD", category: "4k", num: 3)
        ])
        #expect(result["f1fhd"]?.isFollower == false)
        #expect(result["f1hd"]?.isFollower == true)
        #expect(result["f1uhd"]?.isFollower == false)
        #expect(result["f1uhd"]?.qualities == "UHD · FHD · HD")
    }

    @Test func `a hidden quality is out of the group and never the row`() {
        let result = LiveChannelVariants.assignments(for: [
            member("uhd", "TNT Sports 1 UHD", num: 1, hidden: true),
            member("fhd", "TNT Sports 1 FHD", num: 2), member("hd", "TNT Sports 1 HD", num: 3)
        ])
        #expect(result["uhd"] == nil)
        #expect(result["fhd"]?.isFollower == false)
        #expect(result["hd"]?.isFollower == true)
        #expect(result["fhd"]?.qualities == "FHD · HD")
    }

    @Test func `the screen decides between UHD and FHD, frame rate breaks the tie`() {
        func rank(_ name: String, is4K: Bool) -> Int {
            LiveChannelVariants.displayIs4K = is4K
            defer { LiveChannelVariants.displayIs4K = false }
            return LiveChannelVariants.rank(ChannelQuality.parsed(name))
        }
        #expect(rank("Sky Sports F1 FHD", is4K: false) > rank("Sky Sports F1 UHD", is4K: false))
        #expect(rank("Sky Sports F1 UHD", is4K: true) > rank("Sky Sports F1 FHD 50FPS", is4K: true))
        #expect(rank("Sky Sports F1 FHD 50FPS", is4K: false) > rank("Sky Sports F1 FHD", is4K: false))
        #expect(rank("Sky Sports F1 HD", is4K: false) > rank("Sky Sports F1 SD", is4K: false))
    }
}
