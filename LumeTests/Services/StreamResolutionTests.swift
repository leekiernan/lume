import Foundation
@testable import Lume
import Testing

struct StreamResolutionTests {
    private func media(_ id: String) -> PlayableMedia {
        PlayableMedia(
            id: id, url: URL(string: "http://example.com/\(id).ts")!, title: id, subtitle: nil, posterURL: nil,
            kind: .live, startTime: 0, contentRef: .live(id)
        )
    }

    @Test func `a resolve that finishes after the stream changed is dropped`() {
        var resolution = StreamResolution()
        let first = resolution.begin("a")
        let second = resolution.begin("b")

        let staleFinished = resolution.finish(first, with: media("a"))
        #expect(!staleFinished)
        let staleFailed = resolution.fail(first)
        #expect(!staleFailed, "a cancelled resolve's failure doesn't land on the next stream")
        #expect(resolution.state == .resolving(second))

        let finished = resolution.finish(second, with: media("b"))
        #expect(finished)
        #expect(resolution.media(for: "b")?.id == "b")
        #expect(resolution.media(for: "a") == nil)
    }

    @Test func `retrying the same stream outranks the attempt it replaced`() {
        var resolution = StreamResolution()
        let failed = resolution.begin("a")
        let failedFirst = resolution.fail(failed)
        #expect(failedFirst)
        #expect(resolution.hasFailed("a"))

        let retry = resolution.begin("a")
        #expect(!resolution.hasFailed("a"))
        let replacedFinished = resolution.finish(failed, with: media("a"))
        #expect(!replacedFinished)
        let retryFinished = resolution.finish(retry, with: media("a"))
        #expect(retryFinished)
    }

    @Test func `the fallback chain walks the order once and restarts`() {
        var chain = EngineFallbackChain(priority: [.aetherEngine, .ksPlayer])
        #expect(chain.current == .aetherEngine)
        #expect(chain.hasNext)
        let advanced = chain.advance()
        #expect(advanced)
        #expect(chain.current == .ksPlayer)
        #expect(!chain.hasNext)
        let advancedPastEnd = chain.advance()
        #expect(!advancedPastEnd)
        #expect(chain.current == .ksPlayer)
        chain.restart()
        #expect(chain.current == .aetherEngine)
        #expect(EngineFallbackChain(priority: []).current == .defaultValue)
    }

    @Test func `a tile ignores a late report from an engine it fell back from`() {
        var session = PlaybackSessionMachine()
        _ = session.handle(.starting(.aetherEngine, .open))
        let firstFailure = session.handle(.failedToStart(.aetherEngine, canFallBack: true))
        #expect(firstFailure == [.fallBackToNextEngine])
        _ = session.handle(.starting(.ksPlayer, .fallback))
        let started = PlaybackSessionMachine.EngineReport(started: true, buffering: false, playing: true, failed: false)
        let lateReport = session.handle(.reported(.aetherEngine, started))
        #expect(lateReport == nil)
        let lateFailure = session.handle(.failedToStart(.aetherEngine, canFallBack: false))
        #expect(lateFailure == nil)
        #expect(session.state == .starting(.fallback))
    }
}
