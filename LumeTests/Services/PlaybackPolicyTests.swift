//
//  PlaybackPolicyTests.swift
//  LumeTests
//
//  The one policy every engine plays by.
//

@testable import Lume
import Testing

struct PlaybackPolicyTests {
    @Test func `a start error retries only on the last engine`() {
        #expect(PlaybackPolicy.retriesStartupError(canFallBack: false))
        #expect(!PlaybackPolicy.retriesStartupError(canFallBack: true))
    }

    @Test func `the quick window applies only while another engine is left`() {
        #expect(PlaybackPolicy.startupTimeout(quick: true) == 15)
        #expect(PlaybackPolicy.startupTimeout(quick: false) == 40)
        #expect(PlaybackPolicy.startupTimeout(quick: true) < PlaybackPolicy.liveStallTimeout)
    }

    /// A movie's rebuffer fills a deeper buffer than live's, so it waits
    /// longer before rebuilding; both outlast the quick startup window.
    @Test func `a stalled stream is rebuilt after its kind's window`() {
        #expect(PlaybackPolicy.stallTimeout(isLive: true) == 30)
        #expect(PlaybackPolicy.stallTimeout(isLive: false) == 45)
        #expect(PlaybackPolicy.stallTimeout(isLive: true) < PlaybackPolicy.stallTimeout(isLive: false))
    }

    @Test func `tile windows remain shorter without changing full screen deadlines`() {
        #expect(PlaybackPolicy.tileStartupTimeout(quick: true) == 12)
        #expect(PlaybackPolicy.tileStartupTimeout(quick: false) == 25)
        for quick in [false, true] {
            #expect(PlaybackPolicy.tileStartupTimeout(quick: quick) < PlaybackPolicy.startupTimeout(quick: quick))
        }
        #expect(PlaybackPolicy.startupTimeout(quick: true) == 15)
        #expect(PlaybackPolicy.startupTimeout(quick: false) == 40)
    }
}
