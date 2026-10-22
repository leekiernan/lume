import Foundation

extension LiveStream {
    /// The channel's name as its browse row shows it: without the quality tag
    /// when the row stands for several qualities (`LiveChannelVariants`),
    /// since which one plays is the viewer's pick, not the row's.
    var displayName: String {
        variantQualities == nil ? name : ChannelQuality.displayName(name)
    }
}

extension Sequence<LiveStream> {
    /// Each channel once, as the first of its qualities in this order: for a
    /// newest-first list, the one watched last — the quality it opens in.
    func onePerChannel() -> [LiveStream] {
        var channels = Set<String>()
        return filter { $0.variantKey.map { channels.insert($0).inserted } ?? true }
    }
}
