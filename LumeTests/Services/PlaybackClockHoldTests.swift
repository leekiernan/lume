//
//  PlaybackClockHoldTests.swift
//  LumeTests
//
//  The outgoing title's player can report for a moment after a swap. Its
//  closing position and length must not reach the clock, where they would
//  put the next episode in its own last seconds and re-fire auto-advance.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct PlaybackClockHoldTests {
    private func episode(_ id: String) throws -> PlayableMedia {
        try PlayableMedia(
            id: id, url: #require(URL(string: "https://media.test/\(id).mkv")), title: id, subtitle: nil,
            posterURL: nil, kind: .vod, startTime: 0, contentRef: .movie(id)
        )
    }

    @Test func `the outgoing title's position and length are dropped after a swap`() throws {
        let outgoing = try episode("e4")
        let next = try episode("e5")
        let clock = PlaybackClock()
        clock.applyEngine(position: 1454, of: outgoing)
        clock.applyEngine(duration: 1461, of: outgoing)

        clock.reset(for: next)
        clock.holdEngineReports(from: outgoing.id)
        clock.applyEngine(position: 1455, of: outgoing)
        clock.applyEngine(duration: 1461, of: outgoing)

        #expect(clock.current == 0)
        #expect(clock.duration == 0)
    }

    @Test func `the next title's reports release the hold`() throws {
        let outgoing = try episode("e4")
        let next = try episode("e5")
        let clock = PlaybackClock()
        clock.reset(for: next)
        clock.holdEngineReports(from: outgoing.id)

        clock.applyEngine(position: 2, of: next)
        clock.applyEngine(duration: 1475, of: next)

        #expect(clock.current == 2)
        #expect(clock.duration == 1475)
    }
}
