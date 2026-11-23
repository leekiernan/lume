//
//  TrackerPausedProgress.swift
//  Lume
//
//  Sending a recovered position — one saved before a crash or kill — as the
//  pause the session never got to send. Every tracker checks the same thing
//  first: whether it already holds a newer pause for the title, from another
//  device or a later session here, which must win.
//

import Foundation

nonisolated enum TrackerPausedProgress {
    /// Whether any of the tracker's pauses for the title is at least as new as
    /// `pausedAt`. A pause without a readable date counts as oldest.
    static func holdsNewer(_ remotePausedAt: [Date?], than pausedAt: Date) -> Bool {
        remotePausedAt.contains { ($0 ?? .distantPast) >= pausedAt }
    }
}
