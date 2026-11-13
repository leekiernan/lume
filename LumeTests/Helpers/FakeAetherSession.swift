//
//  FakeAetherSession.swift
//  LumeTests
//
//  A scripted AetherEngine session for `AetherEngineCoordinator`: records what
//  the coordinator asked for, and lets a test play the engine's callbacks.
//

#if !os(visionOS)

    import Foundation
    @testable import Lume
    import LumeAetherBridge

    #if canImport(UIKit)
        import UIKit
    #elseif canImport(AppKit)
        import AppKit
    #endif

    @MainActor
    final class FakeAetherSession: AetherSessionDriving {
        var onTime: ((Double, Double) -> Void)?
        var onPhaseChange: ((LumeAetherPhase) -> Void)?
        var onFailure: ((LumeAetherFailure) -> Void)?
        var onLiveSourceReset: (() -> Void)?
        var onAudioDropped: (() -> Void)?
        var onMediaChange: (() -> Void)?
        var onSubtitleText: ((String?) -> Void)?
        var onSubtitleImages: (([LumeAetherSubtitleImage]) -> Void)?

        let videoView = LumeAetherPlatformView()
        var volume: Float = 1
        var currentTime: Double = 0
        var startupCheckpointsCompleted = 0
        var audioTracks: [LumeAetherTrack] = []
        var subtitleTracks: [LumeAetherTrack] = []
        var activeAudioTrackID: Int?
        var activeSubtitleTrackID: Int?
        var videoInfo: LumeAetherVideoInfo?

        /// What the coordinator asked for, in order.
        private(set) var calls: [String] = []
        private(set) var requests: [LumeAetherLoadRequest] = []
        /// How the next load ends: nil returns, a failure throws it.
        var loadFailures: [LumeAetherFailure?] = []
        var acceptsLiveRetry = true

        func load(_ request: LumeAetherLoadRequest) async throws {
            calls.append("load")
            requests.append(request)
            if !loadFailures.isEmpty, let failure = loadFailures.removeFirst() {
                throw failure
            }
        }

        func stop() {
            calls.append("stop")
        }

        func prepareForReplacement() {
            calls.append("prepareForReplacement")
        }

        func play() {
            calls.append("play")
        }

        func pause() {
            calls.append("pause")
        }

        func seek(to seconds: Double) async {
            calls.append("seek(\(Int(seconds)))")
        }

        func setRate(_ rate: Float) {
            calls.append("setRate(\(rate))")
        }

        func retryLiveSourceRecovery() -> Bool {
            calls.append("retryLiveSourceRecovery")
            return acceptsLiveRetry
        }

        func selectAudioTrack(id: Int) {
            calls.append("selectAudioTrack(\(id))")
            activeAudioTrackID = id
        }

        func selectSubtitleTrack(id: Int?) {
            calls.append("selectSubtitleTrack(\(id.map(String.init) ?? "nil"))")
            activeSubtitleTrackID = id
        }

        func addExternalSubtitle(fileURL _: URL, name: String) -> Int {
            calls.append("addExternalSubtitle(\(name))")
            return 900
        }
    }

#endif
