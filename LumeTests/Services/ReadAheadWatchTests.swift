import Foundation
@testable import Lume
import Testing

struct ReadAheadWatchTests {
    /// Plays `seconds` of ticks at 10 Hz from `start`, the playhead moving
    /// with the clock, and returns how many ticks reported a stall.
    private func play(
        _ watch: inout ReadAheadWatch, from start: TimeInterval, seconds: TimeInterval,
        bufferedEnd: (TimeInterval) -> TimeInterval, playhead: TimeInterval = 100,
        duration: TimeInterval = 6000, isPlaying: Bool = true
    ) -> Int {
        var reports = 0
        for step in 0 ..< Int(seconds * 10) {
            let now = start + Double(step) / 10
            let position = isPlaying ? playhead + (now - start) : playhead
            let sample = ReadAheadWatch.Sample(
                playhead: position, bufferedEnd: bufferedEnd(now), duration: duration, maximumBuffer: 30, isPlaying: isPlaying
            )
            if watch.note(sample, now: now) {
                reports += 1
            }
        }
        return reports
    }

    @Test func `a dead connection is reported once, while the buffer still plays`() {
        var watch = ReadAheadWatch()
        // 10 s buffered at the playhead, and nothing more ever arrives.
        #expect(play(&watch, from: 0, seconds: 2.9, bufferedEnd: { _ in 110 }) == 0)
        #expect(play(&watch, from: 2.9, seconds: 0.2, bufferedEnd: { _ in 110 }, playhead: 102.9) == 1)
        #expect(play(&watch, from: 3.1, seconds: 3, bufferedEnd: { _ in 110 }, playhead: 103.1) == 0)
    }

    @Test func `a reading connection is never reported`() {
        var watch = ReadAheadWatch()
        #expect(play(&watch, from: 0, seconds: 10, bufferedEnd: { 110 + $0 * 1.5 }) == 0)
    }

    /// KSPlayer stops reading at the maximum and resumes below half of it.
    @Test func `a full buffer draining is not a dead connection`() {
        var watch = ReadAheadWatch()
        #expect(play(&watch, from: 0, seconds: 10, bufferedEnd: { _ in 130 }) == 0)
    }

    @Test func `nothing is reported while paused`() {
        var watch = ReadAheadWatch()
        #expect(play(&watch, from: 0, seconds: 10, bufferedEnd: { _ in 105 }, isPlaying: false) == 0)
    }

    @Test func `the end of the file has nothing left to read`() {
        var watch = ReadAheadWatch()
        #expect(play(&watch, from: 0, seconds: 10, bufferedEnd: { _ in 6000 }, playhead: 5990) == 0)
    }

    @Test func `reading resuming re-arms the watch`() {
        var watch = ReadAheadWatch()
        #expect(play(&watch, from: 0, seconds: 4, bufferedEnd: { _ in 110 }) == 1)
        // The reopen reads again…
        #expect(play(&watch, from: 4, seconds: 2, bufferedEnd: { 110 + ($0 - 4) * 2 }, playhead: 104) == 0)
        // …and a second drop is reported in its turn.
        #expect(play(&watch, from: 6, seconds: 4, bufferedEnd: { _ in 114 }, playhead: 106) == 1)
    }
}
