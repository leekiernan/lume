//
//  HueSyncController.swift
//  Lume
//
//  Runs Philips Hue light-sync sessions: snapshot the area's lights, persist
//  that snapshot, open the area over CLIP v2, connect the stream and feed it
//  ~50 packets a second from whichever `HueFrameSource` is current. Stopping
//  closes the stream, closes the area, restores the lights and only then
//  forgets the snapshot. Nothing is retried; state is published on events
//  only, never per frame.
//
//  The lifecycle is `HueSyncMachine`; this class performs its effects and
//  holds what they need (client, snapshot, sampler, stream) per session.
//

import Foundation
import Observation
import os

nonisolated enum HueSyncError: Error, Hashable {
    case bridge(HueBridgeError)
    case stream(HueStreamTransportError)
    /// The chosen area has no channels the stream can address.
    case unsupportedArea
}

nonisolated enum HueSyncState: Hashable {
    case idle
    case connecting
    case streaming
    /// Streaming, holding the last colours, because the current source has
    /// no frames to give.
    case unavailable(HueFrameUnavailableReason)
    /// Another app or a Sync Box streams to the area; it is left alone.
    case areaInUse
    case error(HueSyncError)
}

struct HueSyncDependencies {
    var pairedBridge: () -> (address: HueBridgeAddress, secrets: HueBridgeSecrets)?
    var makeClient: (HueBridgeAddress, HueBridgeSecrets) -> HueBridgeClient?
    var makeTransport: (HueBridgeAddress, HueBridgeCredentials) -> (any HueStreamTransport)?
    var defaults: UserDefaults
    /// Seconds on a monotonic clock.
    var now: () -> Double
    /// Nil runs no tick loop; the caller drives `tick()`.
    var tickInterval: Duration?
}

#if os(tvOS)
    extension HueSyncDependencies {
        static var live: HueSyncDependencies {
            let store = HueCredentialStore()
            let clock = ContinuousClock()
            let origin = clock.now
            return HueSyncDependencies(
                pairedBridge: { store.pairedBridgeAndSecrets() },
                makeClient: { HueBridgeClient(bridge: $0, secrets: $1) },
                makeTransport: { DTLSHueStreamTransport(host: $0.host, credentials: $1) },
                defaults: .standard,
                now: {
                    let elapsed = clock.now - origin
                    return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
                },
                tickInterval: .milliseconds(20)
            )
        }
    }
#endif

@Observable
final class HueSyncController {
    #if os(tvOS)
        static let shared = HueSyncController(dependencies: .live)
    #endif

    /// What the UI shows; follows `machine` (see `HueSyncMachine.State.published`).
    private(set) var state: HueSyncState = .idle
    /// The registered source's standing reason it has no frames, whether or
    /// not a session runs.
    private(set) var sourceUnavailableReason: HueFrameUnavailableReason?
    /// The newest failure, for the diagnostic report; outlives the session.
    @ObservationIgnored private(set) var lastError: HueSyncError?

    @ObservationIgnored private let dependencies: HueSyncDependencies
    /// The registered source, which a session started later keeps.
    @ObservationIgnored private(set) weak var frameSource: (any HueFrameSource)?
    @ObservationIgnored private var machine = HueSyncMachine()
    /// The current session's resources; at most one, keyed by its token.
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// Resolves once the machine next settles — no setup, restore or close in
    /// flight; what `start`/`stop`/`suspend` hand back to await.
    @ObservationIgnored private var settleWaiters: [CheckedContinuation<Void, Never>] = []

    init(dependencies: HueSyncDependencies) {
        self.dependencies = dependencies
    }

    // MARK: - Public API

    /// Opens a session, or retargets the running one. `.off` registers the
    /// source and suspends, like `setIntensity(.off)`. The returned task ends
    /// once the area is open and the stream is connecting, or setup ended it.
    @discardableResult
    func start(
        source newSource: (any HueFrameSource)?,
        intensity: HueIntensity,
        reduceMotion: Bool
    ) -> Task<Void, Never> {
        setSource(newSource)
        guard intensity != .off else { return suspend() }
        send(.start(HueSyncMachine.Config(intensity: intensity, reduceMotion: reduceMotion)))
        return settled()
    }

    /// Ends the session: stream closed, area stopped, lights restored. The
    /// returned task ends once the lights are back.
    @discardableResult
    func stop() -> Task<Void, Never> {
        setSource(nil)
        return suspend()
    }

    /// Ends the session like `stop()` but keeps the registered source (its
    /// tap removed until the next frame is asked for), so the player can
    /// resume when the app comes back to the foreground.
    @discardableResult
    func suspend() -> Task<Void, Never> {
        frameSource?.detach()
        send(.stop)
        return settled()
    }

    /// Swaps the frame source without touching the stream. The previous
    /// source's tap is removed.
    func setSource(_ newSource: (any HueFrameSource)?) {
        guard newSource !== frameSource else { return }
        frameSource?.detach()
        frameSource = newSource
        let reason = newSource?.unavailableReason
        if sourceUnavailableReason != reason { sourceUnavailableReason = reason }
    }

    /// Removes `oldSource` unless another source already replaced it; the
    /// engine that is going away may report after its successor registered.
    func clearSource(_ oldSource: any HueFrameSource) {
        guard oldSource === frameSource else { return }
        setSource(nil)
    }

    /// A paired bridge and a chosen entertainment area, from UserDefaults
    /// only; a session whose keys are gone ends itself in `open`.
    var isConfigured: Bool {
        PlayerSettings.Hue.entertainmentAreaID(in: dependencies.defaults) != nil
            && HueCredentialStore(defaults: dependencies.defaults).hasPairing
    }

    /// Opens a session for the registered source when the saved setting and
    /// a configured area allow it, at the saved level.
    func startIfEligible(reduceMotion: Bool) {
        let defaults = dependencies.defaults
        guard !LumeApp.isTestOrPreviewHost,
              PlayerSettings.Hue.isEnabled(in: defaults),
              isConfigured
        else { return }
        start(source: frameSource, intensity: PlayerSettings.Hue.intensity(in: defaults), reduceMotion: reduceMotion)
    }

    /// `.off` ends the session and keeps the source.
    func setIntensity(_ intensity: HueIntensity) {
        guard intensity != .off else {
            suspend()
            return
        }
        guard let config = runningConfig else { return }
        send(.start(HueSyncMachine.Config(intensity: intensity, reduceMotion: config.reduceMotion)))
    }

    func setReduceMotion(_ reduceMotion: Bool) {
        guard let config = runningConfig else { return }
        send(.start(HueSyncMachine.Config(intensity: config.intensity, reduceMotion: reduceMotion)))
    }

    /// Restores lamps a crash left in stream colours. Kept for later while the
    /// area still streams: that may be the crashed stream not yet timed out.
    /// Nil when there is nothing to restore or a session is under way.
    @discardableResult
    func restoreLeftoverSnapshot() -> Task<Void, Never>? {
        guard case .idle = machine.state,
              PlayerSettings.Hue.restoreSnapshot(in: dependencies.defaults) != nil,
              dependencies.pairedBridge() != nil
        else { return nil }
        send(.restoreLeftover)
        return settled()
    }

    /// The config of a session being set up or running.
    private var runningConfig: HueSyncMachine.Config? {
        switch machine.state {
        case let .opening(_, config), let .connecting(_, config), let .streaming(_, config, _): config
        default: nil
        }
    }

    // MARK: - Machine

    private func send(_ event: HueSyncMachine.Event) {
        let before = machine.state
        let effects = machine.handle(event)
        if machine.state != before {
            Logger.player.log("Hue: \(before.logName, privacy: .public) → \(machine.state.logName, privacy: .public)")
            if case let .idle(.failed(error)) = machine.state { lastError = error }
            if case let .closing(_, .failed(error), _) = machine.state { lastError = error }
        }
        let published = machine.state.published
        if state != published { state = published }
        for effect in effects {
            perform(effect)
        }
        resumeSettleWaitersIfSettled()
    }

    private func perform(_ effect: HueSyncMachine.Effect) {
        switch effect {
        case let .open(token, config):
            let session = Session(token: token)
            self.session = session
            Task { await open(session, config: config) }
        case let .apply(config):
            session?.sampler?.setIntensity(config.intensity)
            session?.sampler?.setReduceMotion(config.reduceMotion)
        case let .connect(token):
            guard let session, session.token == token else { return }
            connect(session)
        case .startTicks:
            startTicking()
        case let .close(token):
            stopTicking()
            guard let session, session.token == token else {
                send(.closed(token))
                return
            }
            self.session = nil
            session.transport?.cancel()
            let defaults = dependencies.defaults
            Task {
                if let error = await Self.close(session, defaults: defaults) {
                    self.lastError = .bridge(error)
                }
                self.send(.closed(token))
            }
        case let .restoreLeftover(token):
            Task {
                await restoreLeftover()
                self.send(.leftoverRestored(token))
            }
        }
    }

    /// A task that ends once no setup, restore or close is in flight: the
    /// session is idle, connecting or streaming.
    private func settled() -> Task<Void, Never> {
        if isSettled { return Task {} }
        return Task {
            await withCheckedContinuation { continuation in
                if isSettled {
                    continuation.resume()
                } else {
                    settleWaiters.append(continuation)
                }
            }
        }
    }

    private var isSettled: Bool {
        switch machine.state {
        case .idle, .connecting, .streaming: true
        case .opening, .restoringLeftover, .abandoningOpen, .closing: false
        }
    }

    private func resumeSettleWaitersIfSettled() {
        guard isSettled, !settleWaiters.isEmpty else { return }
        let waiters = settleWaiters
        settleWaiters = []
        waiters.forEach { $0.resume() }
    }

    // MARK: - Effects

    private func restoreLeftover() async {
        let defaults = dependencies.defaults
        guard let snapshot = PlayerSettings.Hue.restoreSnapshot(in: defaults),
              let paired = dependencies.pairedBridge(),
              let client = dependencies.makeClient(paired.address, paired.secrets)
        else { return }
        let areaID = PlayerSettings.Hue.entertainmentAreaID(in: defaults)
        do throws(HueBridgeError) {
            if let areaID, try await client.entertainmentConfiguration(id: areaID).isStreaming {
                return
            }
            try await client.restore(snapshot)
            PlayerSettings.Hue.clearRestoreSnapshot(in: defaults)
        } catch {
            lastError = .bridge(error)
            let reason = LogRedaction.describe(error)
            Logger.player.error("Hue leftover restore failed: \(reason, privacy: .public)")
        }
    }

    private func open(_ session: Session, config: HueSyncMachine.Config) async {
        let token = session.token
        let result = await setUp(session, config: config)
        send(.opened(token, result))
    }

    /// Reads the area, snapshots and persists its lights, builds the sampler
    /// and opens the area. Checks after every await that the session is
    /// still wanted, so a stop mid-setup touches no more of the bridge.
    private func setUp(_ session: Session, config: HueSyncMachine.Config) async -> HueSyncMachine.OpenResult {
        let defaults = dependencies.defaults
        guard let paired = dependencies.pairedBridge(),
              let areaID = PlayerSettings.Hue.entertainmentAreaID(in: defaults),
              let client = dependencies.makeClient(paired.address, paired.secrets)
        else { return .notConfigured }
        session.client = client
        session.areaID = areaID
        session.paired = paired
        do throws(HueBridgeError) {
            let area = try await client.entertainmentConfiguration(id: areaID)
            guard machine.isOpening(session.token) else { return .notConfigured }
            guard !area.isStreaming else { return .areaInUse }
            if let failure = try await prepare(session, area: area, client: client, config: config) {
                return failure
            }
            guard machine.isOpening(session.token) else { return .notConfigured }
            do {
                try await client.startStreaming(areaID: areaID)
            } catch .areaInUse {
                // Put back only what a crashed session left; this session
                // never touched the lamps.
                session.snapshot = nil
                if let leftover = session.leftoverSnapshot {
                    PlayerSettings.Hue.saveRestoreSnapshot(leftover, in: defaults)
                } else {
                    PlayerSettings.Hue.clearRestoreSnapshot(in: defaults)
                }
                return .areaInUse
            }
            session.didStartStream = true
            return .ready
        } catch {
            let reason = LogRedaction.describe(error)
            Logger.player.error("Hue session setup failed: \(reason, privacy: .public)")
            return .failed(.bridge(error))
        }
    }

    /// Captures and persists the area's lights, then builds the sampler. A
    /// result when setup has to end here.
    private func prepare(
        _ session: Session,
        area: HueEntertainmentConfiguration,
        client: HueBridgeClient,
        config: HueSyncMachine.Config
    ) async throws(HueBridgeError) -> HueSyncMachine.OpenResult? {
        let defaults = dependencies.defaults
        // `async let` loses the typed error, so each read is a `Result`.
        async let fetchedServices = Self.result { () async throws(HueBridgeError) in
            try await client.entertainmentServices()
        }
        async let fetchedLights = Self.result { () async throws(HueBridgeError) in
            try await client.lights()
        }
        let services = try await fetchedServices.get()
        let lights = try await fetchedLights.get()
        guard machine.isOpening(session.token) else { return .notConfigured }

        let captured = HueLightSnapshot(
            capturing: lights,
            lightIDs: area.lightIDs(entertainmentServices: services)
        )
        let leftover = PlayerSettings.Hue.restoreSnapshot(in: defaults)
        session.leftoverSnapshot = leftover
        let snapshot = Self.merging(leftover: leftover, captured)
        PlayerSettings.Hue.saveRestoreSnapshot(snapshot, in: defaults)
        session.snapshot = snapshot

        // The config may have been retargeted while the reads ran.
        let current = runningConfig ?? config
        guard let sampler = HueFrameSampler(
            entertainmentConfigurationID: area.id,
            layout: HueChannelLayout(channels: area.channels),
            intensity: current.intensity,
            reduceMotion: current.reduceMotion
        ) else { return .failed(.unsupportedArea) }
        session.sampler = sampler
        return nil
    }

    private static func result<Value>(
        _ body: () async throws(HueBridgeError) -> Value
    ) async -> Result<Value, HueBridgeError> {
        do {
            return try await .success(body())
        } catch {
            return .failure(error)
        }
    }

    private func connect(_ session: Session) {
        let token = session.token
        guard let paired = session.paired,
              let transport = dependencies.makeTransport(paired.address, paired.secrets.credentials)
        else {
            send(.streamFailed(token, .invalidCredentials))
            return
        }
        session.transport = transport
        transport.start { [weak self] transportState in
            Task { @MainActor [weak self] in
                switch transportState {
                case .connecting:
                    break
                case .ready:
                    self?.send(.streamReady(token))
                case let .failed(error):
                    let reason = LogRedaction.describe(error)
                    Logger.player.error("Hue stream ended: \(reason, privacy: .public)")
                    self?.send(.streamFailed(token, error))
                }
            }
        }
    }

    /// Stops the area and restores the lights. The last failure, if any.
    private static func close(_ session: Session, defaults: UserDefaults) async -> HueBridgeError? {
        guard let client = session.client, let areaID = session.areaID else { return nil }
        var failure: HueBridgeError?
        if session.didStartStream {
            do {
                try await client.stopStreaming(areaID: areaID)
            } catch {
                failure = error
                let reason = LogRedaction.describe(error)
                Logger.player.error("Hue stream stop failed: \(reason, privacy: .public)")
            }
        }
        guard let snapshot = session.snapshot else { return failure }
        do {
            try await client.restore(snapshot)
            PlayerSettings.Hue.clearRestoreSnapshot(in: defaults)
        } catch {
            failure = error
            let reason = LogRedaction.describe(error)
            Logger.player.error("Hue light restore failed: \(reason, privacy: .public)")
        }
        return failure
    }

    /// A leftover snapshot holds the lamps' state from before a crashed
    /// stream; what they show now may still be that stream's colours.
    private static func merging(leftover: HueLightSnapshot?, _ captured: HueLightSnapshot) -> HueLightSnapshot {
        guard let leftover else { return captured }
        let known = Set(leftover.lights.map(\.lightID))
        let lights = leftover.lights + captured.lights.filter { !known.contains($0.lightID) }
        return HueLightSnapshot(lights: lights.sorted { $0.lightID < $1.lightID })
    }

    // MARK: - Ticks

    /// Takes the current source's frame reference and hands it to the
    /// sampler. A missing frame resends the last colours, which keeps the
    /// bridge from dropping the stream while playback is paused.
    func tick() {
        guard let session, machine.isStreaming(session.token),
              let sampler = session.sampler, let transport = session.transport
        else { return }
        let sample = frameSource?.latestFrame() ?? .noFrame
        switch sample {
        case let .unavailable(reason):
            if state != .unavailable(reason) { send(.frames(unavailable: reason)) }
        case .frame:
            if state != .streaming { send(.frames(unavailable: nil)) }
        case .noFrame:
            break
        }
        sampler.submit(sample, at: dependencies.now()) { packet in
            transport.send(packet)
        }
    }

    private func startTicking() {
        guard tickTask == nil, let interval = dependencies.tickInterval else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }
}

private extension HueSyncController {
    /// What one session's effects need; the lifecycle is the machine's.
    final class Session {
        let token: RequestToken
        var client: HueBridgeClient?
        var paired: (address: HueBridgeAddress, secrets: HueBridgeSecrets)?
        var areaID: String?
        var snapshot: HueLightSnapshot?
        /// A crashed session's snapshot this one merged in, kept so a refused
        /// start doesn't lose it.
        var leftoverSnapshot: HueLightSnapshot?
        var didStartStream = false
        var sampler: HueFrameSampler?
        var transport: (any HueStreamTransport)?

        init(token: RequestToken) {
            self.token = token
        }
    }
}
