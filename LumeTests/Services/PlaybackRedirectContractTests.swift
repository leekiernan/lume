//
//  PlaybackRedirectContractTests.swift
//  LumeTests
//
//  What each playback engine sends across a cross-origin redirect. Lume hands
//  a media server's credentials only to that server's own origin
//  (`PlaylistConnection.playbackHeaders`), but from there FFmpeg (KSPlayer),
//  AVFoundation and VLC run their own HTTP and follow redirects themselves.
//  Each test opens origin A exactly as the engine's coordinator does; A
//  redirects to origin B, which records what arrived. A direct request to B
//  first proves the probe sees what an engine sends.
//

import AVFoundation
import Foundation
import KSPlayer
import Libavformat
@testable import Lume
import Synchronization
import Testing
import VLCKit

@Suite(.serialized)
struct PlaybackRedirectContractTests {
    /// The credential each source puts on a stream, and how it travels.
    enum Credential: CaseIterable {
        case webDAVBasic, jellyfinToken, plexToken

        var headers: [String: String] {
            switch self {
            case .webDAVBasic: ["Authorization": "Basic " + Data("viewer:s3cret-basic".utf8).base64EncodedString()]
            case .jellyfinToken: JellyfinClient.playbackHeaders(token: "s3cret-jellyfin")!
            case .plexToken: PlexClient.playbackHeaders(token: "s3cret-plex")!
            }
        }

        /// What gives the credential away in a raw request, header or URL.
        var secret: String {
            switch self {
            case .webDAVBasic: Data("viewer:s3cret-basic".utf8).base64EncodedString()
            case .jellyfinToken: "s3cret-jellyfin"
            case .plexToken: "s3cret-plex"
            }
        }
    }

    @Test(arguments: [Engine.ffmpeg, .ksAVFoundation, .avFoundation, .vlc], Credential.allCases)
    func `no engine sends a credential to a cross-origin redirect target`(engine: Engine, credential: Credential) async throws {
        // Userinfo is only sent when asked, and libvlc aborts (a bad free in
        // `vlc_http_auth_Deinit`) when a redirect target answers 401: VLC's
        // target never challenges, so its Basic control can't be shown.
        let challenges = engine != .vlc
        if challenges || credential != .webDAVBasic {
            let control = try await RedirectOrigins.start(secret: credential.secret, targetChallenges: challenges)
            defer { control.stop() }
            await engine.open(control.target, headers: credential.headers)
            #expect(control.targetRequests.contains { $0.contains(credential.secret) }, "probe control")
        }

        let origins = try await RedirectOrigins.start(secret: credential.secret, targetChallenges: challenges)
        defer { origins.stop() }
        await engine.open(origins.redirecting, headers: credential.headers)
        #expect(origins.originRequests.contains { $0.contains(credential.secret) }, "origin A gets its credential")
        #expect(!origins.targetRequests.isEmpty, "the engine followed the redirect")
        #expect(!origins.targetRequests.contains { $0.contains(credential.secret) }, "\(origins.targetRequests.joined(separator: "\n---\n"))")
    }

    /// Why credentials don't travel as headers: handed the stream's headers
    /// as they are, FFmpeg sends every one to the redirect target, and
    /// AVFoundation drops `Authorization` but sends a custom header on.
    @Test(arguments: [RawEngine.ffmpeg, .avFoundation], Credential.allCases)
    func `headers handed to an engine as they are`(engine: RawEngine, credential: Credential) async throws {
        let origins = try await RedirectOrigins.start(secret: credential.secret)
        defer { origins.stop() }
        await engine.open(origins.redirecting, headers: credential.headers)
        let forwarded = origins.targetRequests.contains { $0.contains(credential.secret) }
        #expect(!origins.targetRequests.isEmpty, "the engine followed the redirect")
        #expect(forwarded == (engine == .ffmpeg || credential == .plexToken))
    }

    @Test(arguments: [Engine.ffmpeg, .ksAVFoundation, .avFoundation], Credential.allCases)
    func `a different port is a different credential origin`(engine: Engine, credential: Credential) async throws {
        let origins = try await RedirectOrigins.start(secret: credential.secret, targetHost: "127.0.0.1")
        defer { origins.stop() }
        await engine.open(origins.redirecting, headers: credential.headers)
        #expect(origins.originRequests.contains { $0.contains(credential.secret) })
        #expect(!origins.targetRequests.isEmpty)
        #expect(!origins.targetRequests.contains { $0.contains(credential.secret) })
    }

    @Test(arguments: [Engine.ffmpeg, .ksAVFoundation, .avFoundation, .vlc], Credential.allCases)
    func `same origin redirects retain authentication in the native engine`(engine: Engine, credential: Credential) async throws {
        let log = RequestLog()
        let server = try GuideHTTPServer { request in
            log.append(request)
            if request.contains("/Videos/") { return .init(status: 302, headers: ["Location": "/media/film.mkv"], body: "") }
            return request.contains(credential.secret) ? .init(status: 404, body: "")
                : .init(status: 401, headers: ["WWW-Authenticate": "Basic realm=\"media\""], body: "")
        }
        let base = try await server.start()
        defer { server.stop() }
        let url = base.deletingLastPathComponent().appending(path: "Videos/film.mkv")
        let resource = try await PlaybackResourceResolver.resolve(.init(url: url, headers: credential.headers))
        let count = log.requests.count
        // Exclude the authenticated preparation requests: only the native
        // engine's final request proves the handoff actually works.
        await engine.openPrepared(resource)
        let target = log.requests.dropFirst(count).filter { $0.contains("/media/") }
        #expect(!target.isEmpty)
        #expect(target.contains { $0.contains(credential.secret) })
    }

    @Test(arguments: [Engine.ffmpeg, .ksAVFoundation, .avFoundation, .vlc])
    func `modern Jellyfin authentication reaches the native engine`(engine: Engine) async throws {
        let log = RequestLog()
        let token = "s3cret-modern-jellyfin"
        let server = try GuideHTTPServer { request in
            log.append(request)
            // ApiKey and MediaBrowser remain supported when legacy
            // authorization is disabled; api_key alone does not.
            let authorized = request.contains("ApiKey=\(token)") || request.contains("Token=\"\(token)\"")
            return .init(status: authorized ? 404 : 401, body: "")
        }
        let url = try await server.start()
        defer { server.stop() }
        let headers = try #require(JellyfinClient.playbackHeaders(token: token))
        await engine.openPrepared(.init(url: url, headers: headers))
        #expect(log.requests.contains { $0.contains("ApiKey=\(token)") || $0.contains("Token=\"\(token)\"") })
    }
}

// MARK: - Engines

/// Opens a URL the way each coordinator does, long enough for its HTTP layer
/// to make its requests (and follow a redirect), then lets go.
enum Engine {
    case ffmpeg, ksAVFoundation, avFoundation, vlc

    func open(_ url: URL, headers: [String: String]) async {
        guard let resource = try? await PlaybackResourceResolver.resolve(.init(url: url, headers: headers)) else { return }
        await openPrepared(resource)
    }

    func openPrepared(_ resource: PlaybackResource) async {
        let url = resource.url
        let headers = resource.headers
        switch self {
        case .ffmpeg:
            let input = PlaybackCredentials.input(for: .ksPlayer, url: url, headers: headers)
            await Task.detached {
                // KSPlayerEngineView's options, opened the way MEPlayerItem does.
                let options = KSOptions()
                input.apply(to: options)
                var dictionary = options.formatContextOptions.avOptions
                av_dict_set(&dictionary, "rw_timeout", "3000000", 0)
                var context = avformat_alloc_context()
                _ = avformat_open_input(&context, input.url.absoluteString, nil, &dictionary)
                av_dict_free(&dictionary)
                avformat_close_input(&context)
            }.value
        case .ksAVFoundation:
            // KSPlayer's own AVFoundation player: the same URL and options.
            let input = PlaybackCredentials.input(for: .ksPlayer, url: url, headers: headers)
            let options = KSOptions()
            input.apply(to: options)
            _ = try? await AVURLAsset(url: input.url, options: options.avOptions).load(.isPlayable)
        case .avFoundation:
            // AVPlayerCoordinator's asset.
            let input = PlaybackCredentials.input(for: .avPlayer, url: url, headers: headers)
            let options = input.avFoundationHeaders.map { ["AVURLAssetHTTPHeaderFieldsKey": $0] } ?? [:]
            _ = try? await AVURLAsset(url: input.url, options: options).load(.isPlayable)
        case .vlc:
            // VLCPlayerCoordinator's media, played rather than preparsed: the
            // input is what follows redirects.
            let input = PlaybackCredentials.input(for: .vlc, url: url, headers: headers)
            await MainActor.run {
                guard let media = VLCMedia(url: input.url) else { return }
                VLCProbe.player.media = media
                VLCProbe.player.play()
            }
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run { VLCProbe.player.stop() }
        }
    }
}

@MainActor
private enum VLCProbe {
    /// Headless: dummy outputs, so the test host needs no window or audio.
    static let player = VLCMediaPlayer(library: VLCLibrary(options: ["--vout=dummy", "--aout=dummy"]))
}

/// The engines given the stream's headers directly, as before
/// `PlaybackCredentials`.
enum RawEngine {
    case ffmpeg, avFoundation

    func open(_ url: URL, headers: [String: String]) async {
        switch self {
        case .ffmpeg:
            await Task.detached {
                let options = KSOptions()
                options.appendHeader(headers)
                var dictionary = options.formatContextOptions.avOptions
                av_dict_set(&dictionary, "rw_timeout", "3000000", 0)
                var context = avformat_alloc_context()
                _ = avformat_open_input(&context, url.absoluteString, nil, &dictionary)
                av_dict_free(&dictionary)
                avformat_close_input(&context)
            }.value
        case .avFoundation:
            _ = try? await AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers]).load(.isPlayable)
        }
    }
}

// MARK: - Origins

/// Origin A (127.0.0.1) redirects a request carrying the credential to origin
/// B (localhost, another port: another host and origin), which records it.
/// Both challenge for Basic credentials when a request has none: VLC sends a
/// URL's userinfo only when asked, and an engine replaying stored credentials
/// to a new host would only show it when asked.
final nonisolated class RedirectOrigins: Sendable {
    let redirecting: URL
    let target: URL
    private let origin: GuideHTTPServer
    private let destination: GuideHTTPServer
    private let originLog: RequestLog
    private let targetLog: RequestLog

    var originRequests: [String] {
        originLog.requests
    }

    var targetRequests: [String] {
        targetLog.requests
    }

    private init(origin: GuideHTTPServer, destination: GuideHTTPServer, redirecting: URL, target: URL,
                 originLog: RequestLog, targetLog: RequestLog)
    {
        self.origin = origin
        self.destination = destination
        self.redirecting = redirecting
        self.target = target
        self.originLog = originLog
        self.targetLog = targetLog
    }

    private static let challenge = GuideHTTPServer.Response(
        status: 401, headers: ["WWW-Authenticate": "Basic realm=\"media\""], body: ""
    )

    static func start(secret: String, targetChallenges: Bool = true, targetHost: String = "localhost") async throws -> RedirectOrigins {
        let targetLog = RequestLog()
        let destination = try GuideHTTPServer { request in
            targetLog.append(request)
            let authorized = request.localizedCaseInsensitiveContains("\r\nAuthorization:")
            return authorized || !targetChallenges ? .init(status: 404, body: "") : challenge
        }
        let destinationURL = try await destination.start()
        let target = URL(string: "http://\(targetHost):\(destinationURL.port!)/media/film.mkv")!
        let originLog = RequestLog()
        let origin = try GuideHTTPServer { request in
            originLog.append(request)
            guard request.contains(secret) else { return challenge }
            return .init(status: 302, headers: ["Location": target.absoluteString], body: "")
        }
        let originURL = try await origin.start()
        let redirecting = URL(string: "http://127.0.0.1:\(originURL.port!)/Videos/film.mkv")!
        return RedirectOrigins(origin: origin, destination: destination, redirecting: redirecting, target: target,
                               originLog: originLog, targetLog: targetLog)
    }

    func stop() {
        origin.stop()
        destination.stop()
    }
}

/// The raw requests one origin received.
final nonisolated class RequestLog: Sendable {
    private let lines = Mutex<[String]>([])

    var requests: [String] {
        lines.withLock { $0 }
    }

    func append(_ request: String) {
        lines.withLock { $0.append(request) }
    }
}
