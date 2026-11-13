//
//  AetherEngineCoordinator.swift
//  Lume
//
//  Playback surface for the AetherEngine backend. Owns one engine session for
//  its whole life and loads each stream into it in place. The stream lifecycle
//  is `AetherSessionMachine`'s: this feeds it the session's callbacks and
//  performs its effects, through the startup supervisor and reconnect budget
//  every engine shares. Overlays, fallback and Now Playing stay the host's.
//

#if !os(visionOS)

    import Combine
    import Foundation
    import LumeAetherBridge
    import OSLog

    @MainActor
    final class AetherEngineCoordinator: ObservableObject {
        @Published private(set) var isPlaying = false
        @Published private(set) var isBuffering = false
        @Published private(set) var hasStartedPlayback = false
        /// What `PlaybackSessionMachine` hears (`reportsPlayback`).
        @Published private(set) var report = PlaybackSessionMachine.EngineReport(started: false, buffering: false, playing: false, failed: false)
        @Published var videoInfo: PlayerVideoInfo?
        @Published var audioTrackOptions: [PlayerTrackOption] = []
        @Published var textTrackOptions: [PlayerTrackOption] = []
        /// Published so the host installs the engine's view once the first
        /// `configure` builds the session.
        @Published private(set) var session: (any AetherSessionDriving)?
        /// Active cues on their own observable, so a cue change invalidates
        /// only the subtitle leaf.
        let subtitleCues = SubtitleCueModel()

        /// The engine's playback tick: (current, duration) in seconds, only
        /// while it describes the current stream.
        var onTime: ((TimeInterval, TimeInterval) -> Void)?
        /// The stream can't play here. `allowsNextEngine` is false for a
        /// stream that is gone (404) or a drop after the first frame whose
        /// reconnect budget ran out: show the overlay rather than fall back.
        var onPlaybackFailure: ((_ allowsNextEngine: Bool) -> Void)?
        /// Re-resolves a stream URL whose token expired (Stalker); nil keeps
        /// the current one.
        var resolveFreshURL: (() async -> URL?)?

        var startupTimeout = PlaybackPolicy.startupTimeout
        /// No engine is left to fall back to, so a stream that never played
        /// reconnects rather than failing (`PlaybackPolicy`).
        var retriesStartupErrors = false
        /// A Multi-View tile: secondary output, no display criteria, no
        /// Picture in Picture.
        var isEmbedded = false

        var playbackRate: Float = 1 {
            didSet { session?.setRate(playbackRate) }
        }

        var isMuted = false {
            didSet { if isMuted != oldValue { applyAudioLevel() } }
        }

        /// The full-screen player's volume; every load inherits it.
        var userVolume: Float = 1 {
            didSet { applyAudioLevel() }
        }

        private(set) var machine = AetherSessionMachine()
        private(set) var currentMedia: PlayableMedia?
        private let startup: PlaybackStartupSupervisor
        let retry: PlaybackRetryController
        private let makeSession: () throws -> any AetherSessionDriving
        private let sleep: (Duration) async throws -> Void
        private var loadTask: Task<Void, Never>?
        /// The values registered with the engine's log redaction for the
        /// current load (`AetherLogSecrets`). Never logged.
        private var registeredLogSecrets: Set<String> = []
        /// An audio track picked by hand, carried into a reload of the same
        /// URL so it outranks the preferred languages.
        var manualAudioTrackID: Int?
        var externalSubtitle: ExternalSubtitle?
        var externalSubtitleTrackID: Int?
        var isExternalSubtitleSelected = false

        /// Tests pass a scripted session and an instant clock.
        init(
            startup: PlaybackStartupSupervisor? = nil,
            retry: PlaybackRetryController? = nil,
            makeSession: (() throws -> any AetherSessionDriving)? = nil,
            sleep: ((Duration) async throws -> Void)? = nil
        ) {
            self.startup = startup ?? PlaybackStartupSupervisor()
            self.retry = retry ?? PlaybackRetryController()
            self.makeSession = makeSession ?? { try LumeAetherSession() }
            self.sleep = sleep ?? { try await Task.sleep(for: $0) }
        }

        // MARK: Lifecycle

        /// The player's first stream, or another one in its place (the next
        /// episode, a channel surf, a catch-up segment): loaded in place.
        func configure(media: PlayableMedia) {
            if media.url != currentMedia?.url { manualAudioTrackID = nil }
            start(media, kind: machine.state == .idle ? .open : .replace)
        }

        /// Try Again after the failure overlay.
        func retryAfterFailure() {
            guard let currentMedia else { return }
            start(currentMedia, kind: .retry)
        }

        func tearDown() {
            loadTask?.cancel()
            loadTask = nil
            send(.tearDown)
            releaseLogSecrets()
        }

        private func start(_ media: PlayableMedia, kind: AetherSessionMachine.LoadKind) {
            if session == nil {
                do {
                    session = try buildSession()
                } catch {
                    Logger.player.error("AetherEngine could not start: \(LogRedaction.describe(error), privacy: .public)")
                    currentMedia = media
                    onPlaybackFailure?(true)
                    return
                }
            }
            loadTask?.cancel()
            currentMedia = media
            let plan = loadPlan(for: media)
            send(.load(kind, isLive: media.isLive, startupTimeout: startupTimeout,
                       waitsForLiveJoin: plan.isLive && plan.liveJoinProfile == .standard))
        }

        /// A reconnect of the stream that dropped: VOD resumes where it was,
        /// and an expired token gets a fresh URL first.
        private func reconnect(freshURL: Bool) {
            guard var media = currentMedia else { return }
            if !media.isLive, let position = session?.currentTime, position > 1 {
                media = media.resuming(at: position)
            }
            guard freshURL, let resolveFreshURL else {
                start(media, kind: .reconnect)
                return
            }
            Task {
                let url = await resolveFreshURL()
                guard self.currentMedia?.id == media.id else { return }
                self.start(url.map(media.replacingURL) ?? media, kind: .reconnect)
            }
        }

        // MARK: Transport

        func togglePlay() {
            send(.request(isPlaying ? .pause(.viewer) : .play))
        }

        func play() {
            send(.request(.play))
        }

        func pause(from source: AetherSessionMachine.PauseSource = .viewer) {
            send(.request(.pause(source)))
        }

        func skip(by seconds: Double) {
            guard let session else { return }
            seek(to: max(0, session.currentTime + seconds))
        }

        func seek(to seconds: TimeInterval) {
            let session = session
            Task { await session?.seek(to: seconds) }
        }

        func pictureInPictureDidChange(active: Bool) {
            send(.pictureInPicture(active: active))
        }

        // MARK: Machine

        func send(_ event: AetherSessionMachine.Event) {
            let before = machine.state
            let effects = machine.handle(event)
            if machine.state != before {
                Logger.player.info("AetherEngine: \(Self.logName(before), privacy: .public) → \(Self.logName(machine.state), privacy: .public)")
            }
            for effect in effects {
                perform(effect)
            }
            publishState()
        }

        private func perform(_ effect: AetherSessionMachine.Effect) {
            switch effect {
            case .prepareForReplacement, .startLoad, .finishLoad, .stop, .play, .pause:
                performEngine(effect)
            case .beginStartup, .rearmStartup, .startupSucceeded, .startupFailed, .endStartup:
                performStartup(effect)
            case let .retry(step):
                performRetry(step)
            case let .stall(began):
                if began { PlaybackQoE.shared.noteStallBegan() } else { PlaybackQoE.shared.noteStallEnded() }
            case .schedule, .retryLiveSourceInPlace, .checkLiveSource:
                performRecovery(effect)
            case let .route(failure, route):
                performRoute(failure, route)
            }
        }

        private func performEngine(_ effect: AetherSessionMachine.Effect) {
            switch effect {
            case .prepareForReplacement:
                session?.prepareForReplacement()
                subtitleCues.clear()
            case let .startLoad(token):
                startLoad(token)
            case let .finishLoad(token):
                finishLoad(token)
            case .stop:
                session?.stop()
                subtitleCues.clear()
            case .play:
                session?.play()
            case .pause:
                session?.pause()
            default:
                break
            }
        }

        private func performRecovery(_ effect: AetherSessionMachine.Effect) {
            switch effect {
            case let .schedule(timer, token, delay):
                Task { [weak self, sleep] in
                    try? await sleep(delay)
                    self?.send(.timerFired(timer, token))
                }
            case let .retryLiveSourceInPlace(token):
                let accepted = session?.retryLiveSourceRecovery() ?? false
                send(.liveRetryAnswered(token, accepted: accepted, position: session?.currentTime ?? 0))
            case let .checkLiveSource(token):
                send(.liveSourceChecked(token, position: session?.currentTime ?? 0))
            default:
                break
            }
        }

        private func performStartup(_ effect: AetherSessionMachine.Effect) {
            switch effect {
            case let .beginStartup(token, timeout):
                if let currentMedia, machine.load?.kind != .reconnect {
                    startup.recordSession(engine: .aetherEngine, isLive: currentMedia.isLive, owner: self)
                }
                startup.begin(timeout: timeout) { [weak self] in self?.startupDeadline(token) }
            case let .rearmStartup(token, timeout):
                startup.arm(timeout: timeout) { [weak self] in self?.startupDeadline(token) }
            case .startupSucceeded:
                _ = startup.started()
            case .startupFailed:
                _ = startup.fail()
            case .endStartup:
                startup.end()
            default:
                break
            }
        }

        private func startupDeadline(_ token: RequestToken) {
            let checkpoints = session?.startupCheckpointsCompleted ?? 0
            Logger.player.warning("AetherEngine startup window elapsed at checkpoint \(checkpoints)")
            send(.startupDeadline(token, checkpoints: checkpoints))
        }

        private func performRetry(_ step: AetherSessionMachine.RetryStep) {
            switch step {
            case .newStream: retry.handle(.newStream)
            case .reconnect: retry.handle(.reconnect)
            case .manualRetry: retry.handle(.manualRetry)
            case .healthy: retry.reset()
            case .terminalFailure: retry.handle(.terminalFailure)
            case .teardown: retry.handle(.teardown)
            }
        }

        private func performRoute(_ failure: AetherEngineFailure, _ route: AetherSessionMachine.Route) {
            let cause = failure.rawValue
            let routeName = String(describing: route)
            Logger.player.error("AetherEngine failed: \(cause, privacy: .public) → \(routeName, privacy: .public)")
            switch route {
            case .overlay:
                onPlaybackFailure?(false)
            case .nextEngine:
                onPlaybackFailure?(true)
            case .nextEngineOrReconnect:
                if retriesStartupErrors { scheduleReconnect(freshURL: false) } else { onPlaybackFailure?(true) }
            case let .reconnect(freshURL):
                scheduleReconnect(freshURL: freshURL)
            case .retune:
                scheduleReconnect(freshURL: true)
            }
        }

        /// Through the shared budget; once it's spent, the overlay.
        private func scheduleReconnect(freshURL: Bool) {
            retry.scheduleRetry { [weak self] in self?.reconnect(freshURL: freshURL) }
            if retry.hasGivenUp {
                retry.handle(.terminalFailure)
                onPlaybackFailure?(false)
            }
        }

        private func publishState() {
            if isPlaying != machine.isPlaying { isPlaying = machine.isPlaying }
            if isBuffering != machine.isBuffering { isBuffering = machine.isBuffering }
            if hasStartedPlayback != machine.hasStartedPlayback { hasStartedPlayback = machine.hasStartedPlayback }
            if report != machine.report { report = machine.report }
        }

        // MARK: Loading

        private func startLoad(_ token: RequestToken) {
            guard let session, let media = currentMedia else { return }
            registerLogSecrets(for: media)
            applyAudioLevel()
            let request = LumeAetherLoadRequest(plan: loadPlan(for: media), media: media, audioStreamIndex: manualAudioTrackID)
            loadTask = Task { [weak self] in
                do {
                    try await session.load(request)
                    self?.send(.loadReturned(token))
                } catch is CancellationError {
                    // A newer load or a teardown superseded this one.
                } catch {
                    let failure = error as? LumeAetherFailure
                    self?.logEngineFailure(failure)
                    self?.send(.loadFailed(token, AetherEngineFailure.classify(kind: failure?.kind ?? "", code: failure?.underlyingCode)))
                }
            }
        }

        private func finishLoad(_: RequestToken) {
            guard let session else { return }
            restoreExternalSubtitle(on: session)
            if playbackRate != 1 { session.setRate(playbackRate) }
            publishMedia()
        }

        private func loadPlan(for media: PlayableMedia) -> AetherLoadPlan {
            AetherLoadPlan.make(options: .load(), context: AetherLoadContext(
                isLive: media.isLive,
                isHLSSource: AetherLoadContext.isHLS(media.url),
                httpHeaders: media.httpHeaders,
                preferredAudioLanguages: PlayerLanguageOptions.load().preferredAudioLanguages,
                isEmbedded: isEmbedded
            ))
        }

        /// The engine, built on first use and kept for every later load.
        private func buildSession() throws -> any AetherSessionDriving {
            let session = try makeSession()
            session.onTime = { [weak self] current, duration in
                guard let self, machine.acceptsTime else { return }
                onTime?(current, duration)
            }
            session.onPhaseChange = { [weak self] phase in
                self?.send(.phase(AetherSessionMachine.EnginePhase(phase)))
            }
            session.onFailure = { [weak self] failure in
                self?.logEngineFailure(failure)
                self?.send(.engineFailed(AetherEngineFailure.classify(kind: failure.kind, code: failure.underlyingCode)))
            }
            session.onLiveSourceReset = { [weak self] in
                self?.send(.liveSourceReset(now: .now))
            }
            session.onAudioDropped = { [weak self] in
                Logger.player.error("AetherEngine dropped the audio: no pipeline for the source's audio")
                self?.send(.engineFailed(.unsupported))
            }
            session.onMediaChange = { [weak self] in
                self?.publishMedia()
            }
            session.onSubtitleText = { [weak self] text in
                self?.subtitleCues.update(text)
            }
            session.onSubtitleImages = { [weak self] images in
                self?.subtitleCues.updateBitmaps(images.map {
                    SubtitleBitmap(id: $0.id, image: $0.image, position: $0.position, canvasSize: $0.canvasSize)
                })
            }
            return session
        }

        private func logEngineFailure(_ failure: LumeAetherFailure?) {
            let kind = failure?.kind ?? "-"
            let code = failure?.underlyingCode.map(String.init) ?? "-"
            let message = LogRedaction.scrubURLs(in: failure?.message ?? "")
            Logger.player.error("AetherEngine error \(kind, privacy: .public) (\(code, privacy: .public)): \(message, privacy: .public)")
        }

        func applyAudioLevel() {
            session?.volume = isMuted ? 0 : userVolume
        }

        // MARK: Log secrets

        /// Registers the load's credentials before the engine sees its URL and
        /// releases the previous load's after, so a value both share stays
        /// redacted throughout. Registrations are counted engine-wide.
        private func registerLogSecrets(for media: PlayableMedia) {
            let secrets = AetherLogSecrets.values(url: media.url, httpHeaders: media.httpHeaders)
            for secret in secrets.subtracting(registeredLogSecrets) {
                _ = LumeAetherBridge.registerLogSecret(secret)
            }
            for secret in registeredLogSecrets.subtracting(secrets) {
                LumeAetherBridge.unregisterLogSecret(secret)
            }
            registeredLogSecrets = secrets
        }

        private func releaseLogSecrets() {
            for secret in registeredLogSecrets {
                LumeAetherBridge.unregisterLogSecret(secret)
            }
            registeredLogSecrets = []
        }

        private static func logName(_ state: AetherSessionMachine.State) -> String {
            switch state {
            case .idle: "idle"
            case let .active(load): load.hasStartedPlayback ? "playing(\(load.kind))" : "loading(\(load.kind))"
            case let .failed(_, failure, _): "failed(\(failure.rawValue))"
            }
        }
    }

#endif
