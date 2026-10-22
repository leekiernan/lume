//
//  FullScreenPlayerView+QualityStepDown.swift
//  Lume
//
//  Drops a grouped live channel to its next lower quality when it can't keep
//  up — see `LiveQualityStepDown` for when. Through the same swap as the
//  Source menu, anchored to the same row, so it is not a channel change.
//

import OSLog
import SwiftUI

extension FullScreenPlayerView {
    func noteQualityTransition(from previous: PlaybackSessionMachine.State, to next: PlaybackSessionMachine.State) {
        // Only a channel with other qualities: tuning anchors those.
        guard activeMedia.isLive, activeMedia.channelAnchorID != nil else { return }
        let mediaID = activeMedia.id
        switch next {
        case .rebuffering:
            switch qualityStepDown.stallBegan(on: mediaID, at: .now) {
            case .stepDown:
                stepDownQuality(from: mediaID, reason: "repeated stalls")
            case let .recheck(after):
                Task {
                    try? await Task.sleep(for: .seconds(after))
                    guard activeMedia.id == mediaID, session.state == .rebuffering,
                          qualityStepDown.stallOutlasted(on: mediaID, at: .now) else { return }
                    stepDownQuality(from: mediaID, reason: "a long stall")
                }
            }
        case .failed(.startup):
            if qualityStepDown.failedToStart(on: mediaID) == .stepDown { stepDownQuality(from: mediaID, reason: "no start") }
        default:
            if previous == .rebuffering { qualityStepDown.stallEnded(on: mediaID) }
        }
    }

    /// The next quality down, or nothing when this is the lowest. On the next
    /// main-actor turn, not inside the session event that asked for it: the
    /// swap sends the session events of its own.
    private func stepDownQuality(from mediaID: String, reason: String) {
        Task { stepDownNow(from: mediaID, reason: reason) }
    }

    private func stepDownNow(from mediaID: String, reason: String) {
        guard activeMedia.id == mediaID, case let .live(currentID) = activeMedia.contentRef,
              let current = PlayerContentLookup.liveStream(currentID, in: modelContext),
              let sources = PlayerSourceSwitch.sources(for: activeMedia, restriction: contentRestriction, in: modelContext)
        else { return }
        let qualities = sources.alternatives.compactMap { option -> LiveStream? in
            if case let .live(stream) = option.source.copy { stream } else { nil }
        }
        guard let lower = LiveChannelVariants.stepDown(from: current, among: qualities),
              let option = sources.alternatives.first(where: { $0.source.id == lower.id }) else { return }
        Logger.player.info("quality: \(reason, privacy: .public), stepping down to \(lower.name, privacy: .private)")
        let pick = activeMedia.qualityPickID ?? currentID
        switchMedia(to: option.media.asQuality(anchoredAt: activeMedia.channelRowID, pickID: pick))
    }
}
