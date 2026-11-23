//
//  MultiViewTilePlayer.swift
//  Lume
//
//  Playback for one Multi-View tile: video only — no transport, no scrubber, no
//  Picture in Picture — plus the Stalker resolution and engine-fallback chain the
//  full-screen player uses. Every tile but the one carrying the audio plays
//  muted. The per-engine surfaces live in `MultiViewTilePlayer+Engines.swift`.
//

import OSLog
import SwiftData
import SwiftUI

struct MultiViewTilePlayer: View {
    let media: PlayableMedia
    let isMuted: Bool

    @Environment(\.modelContext) private var modelContext

    /// The user's engine order, resolved the same way the full-screen player
    /// resolves it, so a tile plays on the engine the viewer chose and falls
    /// back identically when it can't open the stream.
    @State private var engines = EngineFallbackChain()
    /// What the tile is doing — the full-screen player's machine. Reports are
    /// gated on the engine the session is on, so a late callback from an engine
    /// being torn down can't act on the channel that replaced it. The tile
    /// doesn't scrobble or save progress, so only `fallBackToNextEngine` of its
    /// effects matters here.
    @State private var session = PlaybackSessionMachine()
    /// The Stalker-resolved stand-in for `media` — see `FullScreenPlayerView`.
    @State private var resolution = StreamResolution()
    /// Bumped by the retry affordance to rebuild the engine from scratch.
    @State private var reloadToken = 0

    init(media: PlayableMedia, isMuted: Bool) {
        self.media = media
        self.isMuted = isMuted
    }

    private var engine: PlayerEngineKind {
        engines.current
    }

    /// The stream to hand the engine — the resolved copy for a Stalker
    /// placeholder, gated on its identity matching the tile's current channel so
    /// a stale resolution never reaches the engine after a channel change. Nil
    /// until the session has started an engine on it.
    private var displayMedia: PlayableMedia? {
        switch session.state {
        case .idle, .resolving, .failed(.resolve), .closed: return nil
        default: break
        }
        guard StalkerLink.isPlaceholder(media.url) else { return media }
        return resolution.media(for: media.id)
    }

    private var showsFailure: Bool {
        session.showsFailure || session.state == .failed(.resolve)
    }

    var body: some View {
        ZStack {
            Color.black

            if let displayMedia {
                engineView(for: displayMedia)
                    // The channel is part of the identity: switching channel has
                    // to tear the engine down and build a fresh one. Keyed on the
                    // engine alone, a switch reused the live engine view, which
                    // left the previous stream playing (the coordinators load in
                    // `onAppear`, and only KSPlayer reloads on a URL change) and
                    // stranded the spinner, because the tile had already latched
                    // "playback started" for the outgoing channel.
                    .id("\(engine.rawValue)-\(media.id)-\(reloadToken)")
            }

            if showsFailure {
                failureBadge
            } else if session.state != .playing {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
        }
        .clipped()
        .task(id: "\(media.id)-\(reloadToken)") {
            await open()
        }
        .onChange(of: media.id) { _, _ in
            // A new channel in this tile restarts the fallback chain: the engine
            // the previous channel ended up on says nothing about this one. The
            // session goes idle until the new channel's task starts it.
            engines.restart()
            _ = session.handle(.leave(.swap))
        }
    }

    @ViewBuilder
    private func engineView(for media: PlayableMedia) -> some View {
        switch engine {
        case .ksPlayer:
            MultiViewKSTile(
                media: media,
                isMuted: isMuted,
                usesQuickStartupTimeout: engines.hasNext,
                onPlaybackStarted: { started(on: .ksPlayer) },
                onPlaybackFailed: { failed(on: .ksPlayer) }
            )
        case .vlcKit:
            MultiViewVLCTile(
                media: media,
                isMuted: isMuted,
                usesQuickStartupTimeout: engines.hasNext,
                onPlaybackStarted: { started(on: .vlcKit) },
                onPlaybackFailed: { failed(on: .vlcKit) }
            )
        case .avPlayer:
            MultiViewAVTile(
                media: media,
                isMuted: isMuted,
                usesQuickStartupTimeout: engines.hasNext,
                onPlaybackStarted: { started(on: .avPlayer) },
                onPlaybackFailed: { failed(on: .avPlayer) }
            )
        case .aetherEngine:
            #if os(visionOS)
                Color.black.onAppear { failed(on: .aetherEngine) }
            #else
                MultiViewAetherTile(
                    media: media,
                    isMuted: isMuted,
                    usesQuickStartupTimeout: engines.hasNext,
                    onPlaybackStarted: { started(on: .aetherEngine) },
                    onPlaybackFailed: { failed(on: .aetherEngine) }
                )
            #endif
        }
    }

    private var failureBadge: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
            Text("Stream unavailable")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
            Button("Try Again") { retry() }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .tint(.white)
        }
        .padding()
        .multilineTextAlignment(.center)
    }

    /// Starts the tile's stream: resolves a Stalker placeholder into a real
    /// (short-lived) URL first; Xtream / m3u streams start straight away.
    private func open() async {
        guard StalkerLink.isPlaceholder(media.url) else {
            _ = session.handle(.starting(engine, .open))
            return
        }
        let ticket = resolution.begin(media.id)
        _ = session.handle(.resolving)
        do {
            let resolved = try await StalkerStreamResolver.resolve(media, container: modelContext.container)
            guard resolution.finish(ticket, with: resolved) else { return }
            _ = session.handle(.starting(engine, .open))
        } catch {
            // A resolve cancelled by a channel change or Try Again fails too;
            // its failure belongs to a stream no longer in this tile.
            guard !Task.isCancelled, resolution.fail(ticket) else { return }
            _ = session.handle(.resolveFailed)
            let detail = (error as? StalkerError)?.logDescription ?? LogRedaction.describe(error)
            Logger.player.error("multi-view: Stalker stream resolution failed: \(detail, privacy: .public)")
        }
    }

    private func started(on kind: PlayerEngineKind) {
        _ = session.handle(.reported(kind, .init(started: true, buffering: false, playing: true, failed: false)))
    }

    /// `kind` couldn't open the stream: try the next engine, or give up and show
    /// the retry affordance once the list is exhausted.
    private func failed(on kind: PlayerEngineKind) {
        guard let effects = session.handle(.failedToStart(kind, canFallBack: engines.hasNext)),
              effects.contains(.fallBackToNextEngine)
        else { return }
        engines.advance()
        Logger.player.log("multi-view: \(kind.rawValue, privacy: .public) could not start the tile; falling back to \(engine.rawValue, privacy: .public)")
        _ = session.handle(.starting(engine, .fallback))
    }

    private func retry() {
        engines.restart()
        _ = session.handle(.leave(.swap))
        reloadToken += 1
    }
}
