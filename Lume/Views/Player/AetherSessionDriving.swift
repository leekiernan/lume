//
//  AetherSessionDriving.swift
//  Lume
//
//  What `AetherEngineCoordinator` needs from an engine session: the bridge's
//  `LumeAetherSession`, or a scripted fake in tests. The members are the
//  bridge's own, so the session conforms as it is.
//

#if !os(visionOS)

    import Foundation
    import LumeAetherBridge

    @MainActor
    protocol AetherSessionDriving: AnyObject {
        var onTime: ((Double, Double) -> Void)? { get set }
        var onPhaseChange: ((LumeAetherPhase) -> Void)? { get set }
        var onFailure: ((LumeAetherFailure) -> Void)? { get set }
        var onLiveSourceReset: (() -> Void)? { get set }
        var onAudioDropped: (() -> Void)? { get set }
        var onMediaChange: (() -> Void)? { get set }
        var onSubtitleText: ((String?) -> Void)? { get set }
        var onSubtitleImages: (([LumeAetherSubtitleImage]) -> Void)? { get set }

        var videoView: LumeAetherPlatformView { get }
        var volume: Float { get set }
        var currentTime: Double { get }
        var startupCheckpointsCompleted: Int { get }
        var audioTracks: [LumeAetherTrack] { get }
        var subtitleTracks: [LumeAetherTrack] { get }
        var activeAudioTrackID: Int? { get }
        var activeSubtitleTrackID: Int? { get }
        var videoInfo: LumeAetherVideoInfo? { get }
        var dynamicRange: LumeAetherDynamicRange { get }
        var playedBitrateMbps: Double? { get }

        func load(_ request: LumeAetherLoadRequest) async throws
        func stop()
        func prepareForReplacement()
        func play()
        func pause()
        func seek(to seconds: Double) async
        func setRate(_ rate: Float)
        @discardableResult func retryLiveSourceRecovery() -> Bool
        func selectAudioTrack(id: Int)
        func selectSubtitleTrack(id: Int?)
        func addExternalSubtitle(fileURL: URL, name: String) -> Int
    }

    extension LumeAetherSession: AetherSessionDriving {}

    extension AetherSessionMachine.EnginePhase {
        init(_ phase: LumeAetherPhase) {
            self = switch phase {
            case .idle: .idle
            case .loading: .loading
            case .playing: .playing
            case .paused: .paused
            case .seeking: .seeking
            case .rebuffering: .rebuffering
            case .stalled: .stalled
            case .ended: .ended
            case .failed: .failed
            }
        }
    }

    extension LumeAetherLoadRequest {
        /// The bridge's request for `plan`. A VOD resume starts at the saved
        /// position; live always joins at the edge.
        init(plan: AetherLoadPlan, media: PlayableMedia, audioStreamIndex: Int?) {
            self.init(
                url: media.url,
                startPosition: !media.isLive && media.startTime > 1 ? media.startTime : nil,
                audioStreamIndex: audioStreamIndex.flatMap { Int32(exactly: $0) },
                httpHeaders: plan.httpHeaders,
                isLive: plan.isLive,
                preferredAudioLanguages: audioStreamIndex == nil ? plan.preferredAudioLanguages : [],
                preferredDecodePath: plan.preferredDecodePath.rawValue,
                escalatesToSoftwarePath: plan.escalatesToSoftwarePath,
                deinterlaceMode: plan.deinterlaceMode.rawValue,
                deinterlaceFieldRate: plan.deinterlaceFieldRate.rawValue,
                usesFastZapLiveJoin: plan.liveJoinProfile == .fastZap,
                forwardBufferSegments: plan.forwardBufferSegments,
                probesize: plan.probesize,
                maxAnalyzeDuration: plan.maxAnalyzeDuration,
                nativeRemoteHLS: plan.nativeRemoteHLS,
                audioBridgeMode: plan.audioBridgeMode.rawValue,
                dolbyVisionHandling: plan.dolbyVisionHandling.rawValue,
                upscalesLowResolutionVideo: plan.upscalesLowResolutionVideo,
                upscalesFullHDVideo: plan.upscalesFullHDVideo,
                untaggedVideoColor: plan.untaggedVideoColor.rawValue,
                audioDelaySeconds: plan.audioDelaySeconds,
                prepareNativeSubtitles: plan.prepareNativeSubtitles,
                recognizesBitmapSubtitleText: plan.recognizesBitmapSubtitleText,
                maxConcurrentSourceRequests: plan.maxConcurrentSourceRequests,
                liveStartupGraceSeconds: plan.liveStartupGraceSeconds,
                writesDisplayCriteria: plan.writesDisplayCriteria,
                isSecondaryOutput: plan.sharedOutputRole == .secondary
            )
        }
    }

#endif
