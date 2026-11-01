//
//  DisplayCriteriaGate.swift
//  Lume
//
//  Decides when KSPlayer's display-mode requests reach the TV.
//
//  With Match Frame Rate or Match Dynamic Range on, every request is an HDMI
//  mode switch. KSPlayer asks once per new frame rate and once per new video
//  format, so a stream's first frame can ask twice in a row, and an episode
//  swap in a slightly different format asks again mid-swap. On tvOS 27.2 a
//  mode switch can stall in the display driver (`IOMobileFramebuffer`
//  swap-wait): the picture freezes, audio carries on, and the watchdog resets
//  the Apple TV three minutes later. Back-to-back switches are the case
//  KSPlayer's own source warns about.
//
//  So requests settle first, and only the last one counts. It goes to the TV
//  only when it differs from the mode already asked for, so an episode in the
//  same format never touches the display. Pure, so the rule is testable
//  without a display.
//

import Foundation

nonisolated struct DisplayCriteriaGate: Equatable {
    struct Criteria: Equatable {
        var refreshRate: Float
        /// `DynamicRange.rawValue`.
        var dynamicRange: Int32

        /// Frame rates within this are the same mode (23.976 vs 23.98).
        static let refreshTolerance: Float = 0.01

        func matches(_ other: Criteria) -> Bool {
            dynamicRange == other.dynamicRange && abs(refreshRate - other.refreshRate) < Self.refreshTolerance
        }
    }

    /// How long requests must stop arriving before the last one is applied.
    static let settleDelay: Duration = .milliseconds(750)

    /// The mode last sent to the TV, until the player clears it.
    private(set) var applied: Criteria?
    /// The latest request still settling.
    private(set) var pending: Criteria?

    /// Records a request. The latest one wins.
    mutating func request(_ criteria: Criteria) {
        pending = criteria
    }

    /// Once requests have settled: true when the pending request should reach
    /// the TV, which then counts it as applied.
    mutating func settle() -> Bool {
        guard let pending else { return false }
        self.pending = nil
        if let applied, applied.matches(pending) { return false }
        applied = pending
        return true
    }

    /// The player cleared the mode, so the next request applies afresh.
    mutating func reset() {
        applied = nil
        pending = nil
    }
}
