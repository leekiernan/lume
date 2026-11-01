//
//  PictureWatchTests.swift
//  LumeTests
//
//  A picture standing still under a moving playhead is reported once, and
//  its recovery once.
//

import Foundation
@testable import Lume
import Testing

struct PictureWatchTests {
    private final class Frame {}
    private let first = Frame()
    private let second = Frame()

    private func id(_ frame: Frame) -> ObjectIdentifier {
        ObjectIdentifier(frame)
    }

    @Test func `a moving picture reports nothing`() {
        var watch = PictureWatch()
        for tick in 0 ..< 50 {
            let frame = tick.isMultiple(of: 2) ? first : second
            let event = watch.note(frame: id(frame), playhead: Double(tick) / 10, isPlaying: true, now: Double(tick) / 10)
            #expect(event == nil)
        }
    }

    @Test func `a frozen frame under a moving playhead is reported once, then its recovery`() {
        var watch = PictureWatch()
        _ = watch.note(frame: id(first), playhead: 10, isPlaying: true, now: 100)
        let early = watch.note(frame: id(first), playhead: 11, isPlaying: true, now: 101)
        #expect(early == nil)
        let stalled = watch.note(frame: id(first), playhead: 12.5, isPlaying: true, now: 102.5)
        #expect(stalled == .stalled(seconds: 2.5))
        let again = watch.note(frame: id(first), playhead: 14, isPlaying: true, now: 104)
        #expect(again == nil)
        let resumed = watch.note(frame: id(second), playhead: 15, isPlaying: true, now: 105)
        #expect(resumed == .resumed(after: 5))
    }

    @Test func `a paused picture is not frozen`() {
        var watch = PictureWatch()
        _ = watch.note(frame: id(first), playhead: 10, isPlaying: false, now: 100)
        let event = watch.note(frame: id(first), playhead: 10, isPlaying: false, now: 110)
        #expect(event == nil)
    }

    @Test func `a stalled playhead is buffering, not a frozen picture`() {
        var watch = PictureWatch()
        _ = watch.note(frame: id(first), playhead: 10, isPlaying: true, now: 100)
        let event = watch.note(frame: id(first), playhead: 10.5, isPlaying: true, now: 105)
        #expect(event == nil)
    }
}
