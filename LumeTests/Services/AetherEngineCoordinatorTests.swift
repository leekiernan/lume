//
//  AetherEngineCoordinatorTests.swift
//  LumeTests
//
//  The coordinator performing `AetherSessionMachine`'s effects against a
//  scripted session: loads in place, time gating, failure routing through the
//  shared reconnect budget, and track picks carried into a reconnect.
//

#if !os(visionOS)

    import Foundation
    @testable import Lume
    import LumeAetherBridge
    import Testing

    @MainActor
    struct AetherEngineCoordinatorTests {
        private let session = FakeAetherSession()

        /// Timers fire at once, except those longer than `holdingOver`, which
        /// never do.
        private func coordinator(holdingOver limit: Duration = .seconds(3600)) -> AetherEngineCoordinator {
            let coordinator = AetherEngineCoordinator(
                retry: PlaybackRetryController(backoff: [0, 0]),
                makeSession: { [session] in session },
                sleep: { delay in
                    if delay > limit { try await Task.sleep(for: .seconds(3600)) }
                    await Task.yield()
                }
            )
            // Never reached in a test; deadlines are driven by hand.
            coordinator.startupTimeout = 600
            return coordinator
        }

        private func media(_ id: String = "film", kind: PlayableMedia.Kind = .vod, url: String? = nil) throws -> PlayableMedia {
            try PlayableMedia(
                id: id, url: #require(URL(string: url ?? "https://example.com/\(id).mkv")), title: id, subtitle: nil,
                posterURL: nil, kind: kind, startTime: 0, contentRef: kind == .live ? .live(id) : .movie(id)
            )
        }

        /// A coordinator playing `media`: its load returned and the picture moves.
        private func playing(_ media: PlayableMedia, holdingOver limit: Duration = .seconds(3600)) async throws -> AetherEngineCoordinator {
            let coordinator = coordinator(holdingOver: limit)
            coordinator.configure(media: media)
            try await waitUntil { coordinator.machine.acceptsTime }
            session.onPhaseChange?(.playing)
            return coordinator
        }

        private func loads() -> Int {
            session.calls.count { $0 == "load" }
        }

        @Test func `the first stream loads, and the next replaces it in place`() async throws {
            let coordinator = try await playing(media())
            #expect(coordinator.isPlaying && coordinator.report.started)
            try coordinator.configure(media: media("next"))
            try await waitUntil { loads() == 2 }
            #expect(session.calls.contains("prepareForReplacement"))
            #expect(!session.calls.contains("stop"))
            #expect(session.requests.last?.url.lastPathComponent == "next.mkv")
        }

        @Test func `time reports wait for the load that replaced the stream`() async throws {
            let coordinator = try await playing(media())
            var ticks: [Double] = []
            coordinator.onTime = { current, _ in ticks.append(current) }
            session.onTime?(5, 100)
            try coordinator.configure(media: media("next"))
            // The previous item's last tick, before the new load returns.
            session.onTime?(6, 100)
            try await waitUntil { coordinator.machine.acceptsTime }
            session.onTime?(0.5, 50)
            #expect(ticks == [5, 0.5])
        }

        @Test func `a stream that never plays hands over to the next engine`() async throws {
            let coordinator = coordinator()
            var failures: [Bool] = []
            coordinator.onPlaybackFailure = { failures.append($0) }
            session.loadFailures = [LumeAetherFailure(kind: "nativeItemFailed", underlyingCode: nil, message: "")]
            try coordinator.configure(media: media())
            try await waitUntil { !failures.isEmpty }
            #expect(failures == [true])
            #expect(session.calls.last == "stop")
        }

        @Test func `the last engine reconnects a stream that never played`() async throws {
            let coordinator = coordinator()
            coordinator.retriesStartupErrors = true
            var failures: [Bool] = []
            coordinator.onPlaybackFailure = { failures.append($0) }
            session.loadFailures = [LumeAetherFailure(kind: "sourceOpenFailed", underlyingCode: nil, message: "")]
            try coordinator.configure(media: media())
            try await waitUntil { loads() == 2 }
            #expect(failures.isEmpty)
        }

        @Test func `a stream that is gone shows the overlay, not the next engine`() async throws {
            let coordinator = try await playing(media())
            var failures: [Bool] = []
            coordinator.onPlaybackFailure = { failures.append($0) }
            session.onFailure?(LumeAetherFailure(kind: "sourceRefused", underlyingCode: 404, message: ""))
            #expect(failures == [false])
            #expect(coordinator.report.failed)
        }

        @Test func `a drop after the first frame reconnects where it was, with the viewer's audio pick`() async throws {
            let coordinator = try await playing(media())
            coordinator.selectAudioTrack(id: "2")
            session.currentTime = 1200
            session.onFailure?(LumeAetherFailure(kind: "sourceOpenFailed", underlyingCode: nil, message: ""))
            try await waitUntil { loads() == 2 }
            #expect(session.requests.last?.startPosition == 1200)
            #expect(session.requests.last?.audioStreamIndex == 2)
            #expect(coordinator.report.started == false)
            #expect(coordinator.machine.hasPlayedStream)
        }

        @Test func `an expired token reconnects at a fresh URL`() async throws {
            let coordinator = try await playing(media("channel", kind: .live))
            coordinator.resolveFreshURL = { URL(string: "https://example.com/fresh.ts") }
            session.onFailure?(LumeAetherFailure(kind: "sourceRefused", underlyingCode: 401, message: ""))
            try await waitUntil { loads() == 2 }
            #expect(session.requests.last?.url.lastPathComponent == "fresh.ts")
        }

        @Test func `the reconnect budget runs out into the overlay`() async throws {
            let coordinator = try await playing(media())
            var failures: [Bool] = []
            coordinator.onPlaybackFailure = { failures.append($0) }
            session.loadFailures = [
                LumeAetherFailure(kind: "sourceOpenFailed", underlyingCode: nil, message: ""),
                LumeAetherFailure(kind: "sourceOpenFailed", underlyingCode: nil, message: "")
            ]
            session.onFailure?(LumeAetherFailure(kind: "sourceOpenFailed", underlyingCode: nil, message: ""))
            try await waitUntil { failures == [false] }
            #expect(failures == [false])
            #expect(loads() == 3)
        }

        @Test func `a parked live source is retried in place, not reloaded`() async throws {
            // The backoff passes; the check after the retry is still pending.
            let coordinator = try await playing(media("channel", kind: .live), holdingOver: .seconds(5))
            session.onLiveSourceReset?()
            try await waitUntil { session.calls.contains("retryLiveSourceRecovery") }
            #expect(loads() == 1)
            #expect(coordinator.machine.liveRecovery != nil)
        }

        @Test func `a live channel the engine paused by itself is asked to play again`() async throws {
            let coordinator = try await playing(media("channel", kind: .live))
            session.onPhaseChange?(.paused)
            #expect(session.calls.last == "play")
            #expect(coordinator.report.buffering && !coordinator.report.playing)
        }

        @Test func `a viewer's pause is the engine's pause`() async throws {
            let coordinator = try await playing(media("channel", kind: .live))
            coordinator.togglePlay()
            session.onPhaseChange?(.paused)
            #expect(session.calls.last == "pause")
            #expect(!coordinator.report.buffering)
        }

        @Test func `a subtitle picked on one episode is put back on the next`() async throws {
            let carry = TrackCarryOverSession()
            let coordinator = coordinator()
            coordinator.trackCarryOver = carry
            let episode = { (id: String) in
                try PlayableMedia(
                    id: id, url: #require(URL(string: "https://example.com/\(id).mkv")), title: id, subtitle: nil,
                    posterURL: nil, kind: .vod, startTime: 0, contentRef: .episode(id)
                )
            }
            let tracks = [
                LumeAetherTrack(id: 3, name: "English", codec: "subrip", language: "eng", channels: 0, sampleRate: 0,
                                isDefault: false, isForced: false, isExternal: false),
                LumeAetherTrack(id: 4, name: "Deutsch", codec: "subrip", language: "ger", channels: 0, sampleRate: 0,
                                isDefault: false, isForced: false, isExternal: false)
            ]
            session.subtitleTracks = tracks
            try coordinator.configure(media: episode("e1"))
            try await waitUntil { coordinator.machine.acceptsTime }
            coordinator.selectTextTrack(id: "4")
            // The next episode lists the same languages under other ids.
            session.subtitleTracks = []
            try coordinator.configure(media: episode("e2"))
            try await waitUntil { coordinator.machine.acceptsTime }
            session.subtitleTracks = tracks.map {
                LumeAetherTrack(id: $0.id + 10, name: $0.name, codec: $0.codec, language: $0.language, channels: 0,
                                sampleRate: 0, isDefault: false, isForced: false, isExternal: false)
            }
            session.onMediaChange?()
            #expect(session.calls.last == "selectSubtitleTrack(14)")
        }

        @Test func `teardown stops the engine`() async throws {
            let coordinator = try await playing(media())
            coordinator.tearDown()
            #expect(session.calls.last == "stop")
            #expect(!coordinator.isPlaying)
        }
    }

#endif
