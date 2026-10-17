import Foundation
@testable import Lume
import Testing

@MainActor
struct NowPlayingTransportRegistryTests {
    @Test func `a new host never inherits the old host's transport while mounting`() {
        let old = ActivityLease()
        let current = ActivityLease()
        let oldEngine = NSObject()
        let currentEngine = NSObject()
        var ownership = NowPlayingSessionOwnership()
        var registry = NowPlayingTransportRegistry()
        registry.attach(transport(playing: false), owner: oldEngine, host: old)
        _ = ownership.claim(old)
        #expect(registry.transport(for: ownership.owner)?.isPlaying() == false)
        _ = ownership.claim(current)
        #expect(registry.transport(for: ownership.owner) == nil)
        // The late PiP callback still names the old host, even while its engine
        // remains attached and the new engine has not appeared yet.
        let staleRelease = ownership.release(old)
        #expect(!staleRelease)
        registry.attach(transport(playing: true), owner: currentEngine, host: current)
        registry.remove(host: old)
        #expect(registry.transport(for: ownership.owner)?.isPlaying() == true)
    }

    @Test func `attachment before session publication works and stale engine detach is ignored`() {
        let host = ActivityLease()
        let oldEngine = NSObject()
        let replacement = NSObject()
        var ownership = NowPlayingSessionOwnership()
        var registry = NowPlayingTransportRegistry()
        registry.attach(transport(playing: false), owner: oldEngine, host: host)
        registry.attach(transport(playing: true), owner: replacement, host: host)
        registry.detach(owner: oldEngine, host: host)
        _ = ownership.claim(host)
        #expect(registry.transport(for: ownership.owner)?.isPlaying() == true)
        registry.detach(owner: replacement, host: host)
        #expect(registry.transport(for: ownership.owner) == nil)
    }

    private func transport(playing: Bool) -> NowPlayingService.Transport {
        .init(isPlaying: { playing }, play: {}, pause: {}, seek: { _ in })
    }
}
