//
//  MultiViewAetherTile.swift
//  Lume
//
//  AetherEngine's video-only Multi-View tile. Embedded: secondary output, no
//  display criteria and no Picture in Picture, all of which belong to the one
//  full-screen stream. The coordinator's own reconnects keep a dropped tile
//  going; only a stream that never plays, or one that is gone, reaches the
//  tile's failure badge.
//

#if !os(visionOS)

    import SwiftUI

    struct MultiViewAetherTile: View {
        let media: PlayableMedia
        let isMuted: Bool
        let usesQuickStartupTimeout: Bool
        var onPlaybackStarted: () -> Void
        var onPlaybackFailed: () -> Void

        @StateObject private var coordinator = AetherEngineCoordinator()

        var body: some View {
            AetherEngineVideoSurface(videoView: coordinator.session?.videoView)
                .hueFrameSource(coordinator)
                .onAppear {
                    coordinator.isEmbedded = true
                    coordinator.isMuted = isMuted
                    coordinator.startupTimeout = PlaybackPolicy.tileStartupTimeout(quick: usesQuickStartupTimeout)
                    coordinator.onPlaybackFailure = { _ in onPlaybackFailed() }
                    coordinator.configure(media: media)
                }
                .onDisappear { coordinator.tearDown() }
                .onChange(of: isMuted) { _, muted in coordinator.isMuted = muted }
                .onChange(of: coordinator.hasStartedPlayback) { _, started in
                    if started { onPlaybackStarted() }
                }
        }
    }

#endif
