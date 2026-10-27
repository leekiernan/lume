//
//  KSPlayerEngineView+ReadAhead.swift
//  Lume
//
//  The VOD read-ahead watch: reopens a movie or episode whose connection died
//  while its buffer is still playing. See `ReadAheadWatch`.
//

import KSPlayer
import OSLog
import QuartzCore

extension KSPlayerEngineView {
    /// Reopen a movie or episode whose connection has died while its buffer
    /// still plays — see `ReadAheadWatch`. The reopen fetches a fresh token
    /// while the buffer keeps playing, and resumes at the playhead it reaches,
    /// so the viewer sees a reopen rather than a stall. The stall watchdog
    /// stays behind it for anything this misses.
    func noteReadAhead() {
        guard !media.isLive, hasStartedPlayback, !isSeeking, !loadFailed, let layer = coordinator.playerLayer else {
            tick.readAhead = ReadAheadWatch()
            return
        }
        let player = layer.player
        let sample = ReadAheadWatch.Sample(
            playhead: player.currentPlaybackTime, bufferedEnd: player.playableTime, duration: player.duration,
            maximumBuffer: layer.options.maxBufferDuration, isPlaying: player.isPlaying
        )
        let stalled = tick.readAhead.note(sample, now: CACurrentMediaTime())
        guard stalled else { return }
        let left = player.playableTime - player.currentPlaybackTime
        Logger.player.error("read-ahead stalled with \(left, format: .fixed(precision: 1), privacy: .public)s buffered, reopening the stream")
        reconnector.scheduleRetry { reconnect(rebuilding: true) }
        if reconnector.hasGivenUp { failPlayback() }
    }
}
