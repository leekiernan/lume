//
//  LiveQualityStepDown.swift
//  Lume
//
//  When to drop a struggling live channel to its next lower quality
//  (`LiveChannelVariants`): a stream that can't start at all, one long stall,
//  or stalls coming back again and again. Fed the session's stalls by the
//  host (`PlaybackSessionMachine`'s `rebuffering`), it answers whether to step
//  down now, or when to look again. It never steps up: a connection that
//  struggled once is the viewer's to retry, from the Source menu.
//
//  The step down is not the viewer's choice: the quality they were on keeps
//  the watch stamp (`PlayableMedia.qualityPickID`), so the channel still opens
//  in it next time.
//

import Foundation

nonisolated struct LiveQualityStepDown: Equatable {
    /// A stall this long means the stream can't keep up.
    static let longStall: TimeInterval = 8
    /// This many stalls within `stallWindow` mean the same, a little at a time.
    static let repeatedStalls = 3
    static let stallWindow: TimeInterval = 60

    enum Decision: Equatable {
        case stepDown
        /// Ask `stallOutlasted` again once this many seconds have passed.
        case recheck(after: TimeInterval)
    }

    /// The stream the counts belong to; a new one starts them afresh.
    private var mediaID: String?
    private var stalls: [Date] = []
    private var stallBegan: Date?

    /// A stall began on `mediaID`.
    mutating func stallBegan(on mediaID: String, at now: Date) -> Decision {
        adopt(mediaID)
        stalls = stalls.filter { now.timeIntervalSince($0) < Self.stallWindow } + [now]
        stallBegan = now
        if stalls.count >= Self.repeatedStalls { return stepped() }
        return .recheck(after: Self.longStall)
    }

    mutating func stallEnded(on mediaID: String) {
        guard mediaID == self.mediaID else { return }
        stallBegan = nil
    }

    /// Whether the stall that began on `mediaID` is still going and has run
    /// `longStall`. A recheck for a stall that has since ended, or for another
    /// stream, says no.
    mutating func stallOutlasted(on mediaID: String, at now: Date) -> Bool {
        guard mediaID == self.mediaID, let stallBegan, now.timeIntervalSince(stallBegan) >= Self.longStall else { return false }
        _ = stepped()
        return true
    }

    /// The stream never started, with every engine tried.
    mutating func failedToStart(on mediaID: String) -> Decision {
        adopt(mediaID)
        return stepped()
    }

    private mutating func adopt(_ mediaID: String) {
        guard mediaID != self.mediaID else { return }
        self.mediaID = mediaID
        stalls = []
        stallBegan = nil
    }

    /// Steps once per stream: the next quality starts its own count.
    private mutating func stepped() -> Decision {
        stalls = []
        stallBegan = nil
        mediaID = nil
        return .stepDown
    }
}
