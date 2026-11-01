//
//  KSPlayerEngineView+Diagnostics.swift
//  Lume
//
//  Log lines for a picture that freezes over playing audio: each stream's
//  video format, the engine's state changes, and a frozen picture with what
//  the renderer reported at that moment. Logging only; nothing here acts.
//

import AVFoundation
import KSPlayer
import OSLog
import QuartzCore

extension KSPlayerEngineView {
    /// Each engine state change, so a freeze can be placed against them.
    func logStateChange(_ state: KSPlayerState) {
        Logger.player.info("KSPlayer state → \(String(describing: state), privacy: .public)")
    }

    /// The format of the video track that just opened. An episode in a
    /// different format from the last one makes KSPlayer replace its display
    /// surface mid-swap.
    func logVideoFormat() {
        guard let player = coordinator.playerLayer?.player else { return }
        guard let track = player.tracks(mediaType: .video).first(where: \.isEnabled) else {
            Logger.player.info("video format: no video track")
            return
        }
        let size = track.naturalSize
        let codec = Self.fourCC(track.codecType)
        let range = track.dynamicRange.map { String(describing: $0) } ?? "unknown"
        let transfer = track.transferFunction ?? "unknown"
        let frameRate = track.nominalFrameRate
        let fieldOrder = String(describing: track.fieldOrder)
        let shape = "\(codec) \(Int(size.width))×\(Int(size.height)), \(track.bitDepth)-bit"
        let rate = String(format: "%.3f fps", frameRate)
        let format = "\(shape) \(rate), range \(range), transfer \(transfer), field order \(fieldOrder)"
        Logger.player.info("video format: \(format, privacy: .public)")
        logAudioFormat(player)
    }

    /// The audio track's format beside the HDMI route's. A channel-count
    /// change between episodes can make the Apple TV renegotiate HDMI, much as
    /// a display-mode switch does.
    private func logAudioFormat(_ player: some MediaPlayerProtocol) {
        #if os(macOS)
            let output = "output n/a"
        #else
            let route = AVAudioSession.sharedInstance()
            let output = "output \(route.outputNumberOfChannels)ch @ \(Int(route.sampleRate)) Hz"
        #endif
        guard let track = player.tracks(mediaType: .audio).first(where: \.isEnabled),
              let description = track.audioStreamBasicDescription
        else {
            Logger.player.info("audio format: unknown, \(output, privacy: .public)")
            return
        }
        let codec = Self.fourCC(track.codecType)
        let format = "\(codec) \(description.mChannelsPerFrame)ch @ \(Int(description.mSampleRate)) Hz"
        Logger.player.info("audio format: \(format, privacy: .public), \(output, privacy: .public)")
    }

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
            Logger.player.error("picture frozen \(timing, privacy: .public), state \(state, privacy: .public), \(renderer, privacy: .public)")
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

    /// Printable characters only: a code of zero bytes (FFmpeg-only codecs
    /// such as Opus have no CoreMedia code) put a NUL in the string, which
    /// cut the whole log line short.
    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let printable = bytes.filter { $0 >= 0x20 && $0 < 0x7F }
        let text = (String(bytes: printable, encoding: .ascii) ?? "").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "codec \(code)" : text
    }
}
