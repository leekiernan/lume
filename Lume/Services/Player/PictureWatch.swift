//
//  PictureWatch.swift
//  Lume
//
//  Notices the picture standing still while the playhead moves on: a frozen
//  frame over playing audio. Diagnostic only. It reports the stall and its end
//  so the log shows when a picture froze and what the renderer said then, and
//  takes no action.
//
//  KSPlayer hands each decoded frame over as a new pixel buffer, so the
//  buffer last handed over changing is the picture moving. Pure, so the rule
//  is testable without a player.
//

import Foundation

nonisolated struct PictureWatch: Equatable {
    enum Event: Equatable {
        /// The picture has stood still this long while the playhead moved.
        case stalled(seconds: TimeInterval)
        /// The picture moved again after a reported stall of this long.
        case resumed(after: TimeInterval)
    }

    /// How long the picture may stand still under a moving playhead before
    /// it counts as frozen. Longer than any slow frame rate or decode hiccup.
    static let stallWindow: TimeInterval = 2

    private var frame: ObjectIdentifier?
    private var frameSince: TimeInterval?
    private var playheadAtFrame: TimeInterval = 0
    private var reported = false

    /// Feeds one tick. Returns an event at most once per stall and once when
    /// it ends.
    mutating func note(frame current: ObjectIdentifier?, playhead: TimeInterval, isPlaying: Bool, now: TimeInterval) -> Event? {
        guard let current, playhead.isFinite else { return nil }
        guard current == frame, let since = frameSince else {
            let event: Event? = reported ? .resumed(after: now - (frameSince ?? now)) : nil
            frame = current
            frameSince = now
            playheadAtFrame = playhead
            reported = false
            return event
        }
        let still = now - since
        guard isPlaying, !reported, still >= Self.stallWindow, playhead - playheadAtFrame >= Self.stallWindow else {
            return nil
        }
        reported = true
        return .stalled(seconds: still)
    }
}
