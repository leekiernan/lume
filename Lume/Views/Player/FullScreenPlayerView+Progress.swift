//
//  FullScreenPlayerView+Progress.swift
//  Lume
//
//  Saving the playhead: sampled into the crash-recovery buffer during
//  playback, written to the store at boundaries. Split from
//  FullScreenPlayerView.swift for its length limit.
//

import Foundation
import OSLog

extension FullScreenPlayerView {
    /// Seconds between buffer samples. They only write `UserDefaults`, so this
    /// trades crash-recovery granularity against nothing measurable.
    static let progressSampleInterval: TimeInterval = 30

    /// Stash the current position in `WatchProgressBuffer`: two clock reads on
    /// the main actor, the write on the buffer's background queue. Live
    /// streams and titles already settled as finished have nothing to resume.
    func bufferProgress(waitUntilWritten: Bool = false) {
        guard !activeMedia.isLive, let writer = progressWriter, writer.scope.isCurrent else { return }
        let ref = activeMedia.contentRef
        guard ref != completedRef else { return }
        WatchProgressBuffer.record(
            ref: ref, progress: clock.elapsed(fallback: activeMedia.startTime), duration: clock.duration,
            profileID: writer.scope.profileID, waitUntilWritten: waitUntilWritten
        )
    }

    /// Commit the current progress to SwiftData off the main thread, at a
    /// playback boundary — leaving the foreground, a stream change, close —
    /// never on a timer, where even a background-context save makes the main
    /// context merge and re-run every `@Query` on `Movie`/`Episode`/`Series`
    /// mid-playback. Between boundaries the buffer holds the position for a
    /// crash or kill to leave behind. Captures the clock synchronously
    /// *before* awaiting, so a subsequent `clock.reset()` can't race the read.
    func persistProgressDetached(holdingLive: Bool = false) {
        guard let writer = progressWriter, writer.scope.isCurrent else { return }
        let ref = activeMedia.contentRef
        // An explicit "next episode" already settled this stream at its full
        // duration. Recording the position it was skipped from would walk that
        // back to unwatched, so the completion stands and this flush stands down.
        if ref == completedRef { return }
        let now = clock.elapsed(fallback: activeMedia.startTime)
        let total = clock.duration
        let recordedAt = Date.now
        let isExit = session.state == .closed || session.state == .idle
        let discardEarly = isExit && PlaybackResumePolicy.discardsProgress(position: now, duration: total)
        // What was written, so a resume point that looks wrong can be checked
        // against a diagnostics report.
        Logger.player.info("progress saved: \(now, format: .fixed(precision: 1))s of \(total, format: .fixed(precision: 0))s")
        // The screen reopening this title reads a model that may not have
        // caught up with the write below yet — see `RecentResumePoints`.
        if discardEarly {
            RecentResumePoints.record(0, for: ref, profileID: writer.scope.profileID)
        } else if now > 0 {
            RecentResumePoints.record(now, for: ref, profileID: writer.scope.profileID)
        }
        // Held so `endReviewSession` can await it: `writer` is an actor, so the
        // await below suspends, and without the handle the review policy would
        // read `completedTitles` before this task increments it — the third
        // finished title would then only arm the *next* session.
        let previous = pendingProgressWrite
        pendingProgressWrite = Task { @MainActor in
            await previous?.value
            guard writer.scope.isCurrent else { return }
            // Written to the store now, or deliberately not: either way the
            // buffered copy has nothing left to recover.
            defer { WatchProgressBuffer.remove(ref: ref, profileID: writer.scope.profileID) }
            if discardEarly, MediaWatchState.discardEarlyProgress(ref: ref, position: now, duration: total, in: modelContext) {
                Logger.player.info("early exit: resume progress cleared (below 1%)")
                return
            }
            // Under a background-task assertion: this often runs as the app
            // leaves the foreground, where a suspension would strand it.
            let change = await BackgroundActivity.perform("Watch progress") {
                await writer.record(ref: ref, progress: now, duration: total, holdLive: holdingLive, recordedAt: recordedAt)
            }
            if let change { applyWatchedChange(change) }
        }
    }
}
