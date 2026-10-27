//
//  ReadAheadWatch.swift
//  Lume
//
//  Notices a movie or episode whose connection has died while its buffer is
//  still playing out.
//
//  A provider can drop a VOD connection at any time — most often during a
//  pause, when the token URL it was opened on expires. Playback carries on
//  from what is buffered, so nothing looks wrong until the buffer runs dry and
//  the player stalls, retrying a URL that can no longer answer. The engine's
//  read-ahead shows it first: the buffered end stops moving while the playhead
//  catches up with it. Noticing that while the buffer still lasts leaves time
//  to reopen on a fresh token before the viewer ever sees a stall.
//
//  A standing buffered end isn't always a dead connection. KSPlayer stops
//  reading once the buffer passes its maximum and only resumes below half of
//  it, so a full buffer drains with its end standing still. Below that half a
//  working connection is always reading, which is the only range watched.
//  Pure, so the rule is testable without a player.
//

import Foundation

nonisolated struct ReadAheadWatch: Equatable {
    /// How long the buffered end may stand still, below half the maximum
    /// buffer and while playing, before the connection counts as gone. Short,
    /// because the rest of the buffer is the time left to reopen in.
    static let stallWindow: TimeInterval = 3
    /// Within this of the end of the file there is nothing left to read.
    static let endOfFileMargin: TimeInterval = 1
    /// Smaller movements are clock jitter, not reading.
    static let advanceTolerance: TimeInterval = 0.05

    /// One tick's reading of the engine.
    struct Sample {
        var playhead: TimeInterval
        /// How far the stream is buffered to, on the playhead's timeline.
        var bufferedEnd: TimeInterval
        /// Zero when unknown.
        var duration: TimeInterval
        /// Where reading ahead pauses (`KSOptions.maxBufferDuration`).
        var maximumBuffer: TimeInterval
        var isPlaying: Bool
    }

    private var bufferedEnd: TimeInterval?
    private var stillSince: TimeInterval?
    /// Reported once per stall, until reading is seen to resume.
    private var reported = false

    /// Feeds one tick. True exactly once when the read-ahead has stalled.
    mutating func note(_ sample: Sample, now: TimeInterval) -> Bool {
        let end = sample.bufferedEnd
        guard sample.playhead.isFinite, end.isFinite else {
            self = Self()
            return false
        }
        defer { bufferedEnd = end }
        // Reading moved the end on (or a new stream started behind it).
        if let previous = bufferedEnd, abs(end - previous) > Self.advanceTolerance {
            stillSince = nil
            reported = false
            return false
        }
        let atEndOfFile = sample.duration > 0 && end >= sample.duration - Self.endOfFileMargin
        let readAhead = end - sample.playhead
        guard sample.isPlaying, !atEndOfFile, readAhead < sample.maximumBuffer / 2 else {
            stillSince = nil
            return false
        }
        guard let since = stillSince else {
            stillSince = now
            return false
        }
        guard !reported, now - since >= Self.stallWindow else { return false }
        reported = true
        return true
    }
}
