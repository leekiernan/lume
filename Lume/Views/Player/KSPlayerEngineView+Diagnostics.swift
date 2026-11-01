//
//  KSPlayerEngineView+Diagnostics.swift
//  Lume
//
//  Logs a picture that freezes over playing audio, with what the renderer
//  reported at that moment, and its recovery. Logging only; nothing here acts.
//

import AVFoundation
import KSPlayer
import OSLog
import QuartzCore

extension KSPlayerEngineView {
    /// Logs a picture that stands still while the playhead moves, and its
    /// recovery — see `PictureWatch`.
    func notePicture() {
        guard hasStartedPlayback, let layer = coordinator.playerLayer, let player = layer.player as? KSMEPlayer else {
            tick.picture = PictureWatch()
            return
        }
        let frame = player.videoOutput?.pixelBuffer.map { ObjectIdentifier($0) }
        let event = tick.picture.note(
            frame: frame, playhead: player.currentPlaybackTime, isPlaying: player.isPlaying, now: CACurrentMediaTime()
        )
        switch event {
        case let .stalled(seconds):
            let renderer = Self.describe(player.videoOutput?.displayLayer)
            let state = String(describing: layer.state)
            let timing = String(format: "for %.1fs at %.1fs", seconds, player.currentPlaybackTime)
            // A rebuffer holds the last frame by design; only a picture stuck
            // while the engine says it's playing is a problem worth reporting.
            if layer.state == .buffering {
                Logger.player.info("picture held \(timing, privacy: .public) while buffering, \(renderer, privacy: .public)")
            } else {
                Logger.player.error("picture frozen \(timing, privacy: .public), state \(state, privacy: .public), \(renderer, privacy: .public)")
            }
        case let .resumed(after):
            Logger.player.info("picture moving again after \(after, format: .fixed(precision: 1), privacy: .public)s")
        case nil:
            break
        }
    }

    private static func describe(_ displayLayer: AVSampleBufferDisplayLayer?) -> String {
        guard let displayLayer else { return "no display layer" }
        let renderer = displayLayer.sampleBufferRenderer
        let status = switch renderer.status {
        case .rendering: "rendering"
        case .failed: "failed"
        case .unknown: "unknown"
        @unknown default: "status \(renderer.status.rawValue)"
        }
        let error = renderer.error.map { " (\($0.localizedDescription))" } ?? ""
        let attached = displayLayer.superlayer == nil ? "detached" : "attached"
        return "renderer \(status)\(error), flush needed \(renderer.requiresFlushToResumeDecoding), layer \(attached)"
    }
}
