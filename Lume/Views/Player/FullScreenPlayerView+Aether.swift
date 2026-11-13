//
//  FullScreenPlayerView+Aether.swift
//  Lume
//
//  What the AetherEngine host needs from the full-screen player beyond what
//  every engine gets.
//

import SwiftData
import SwiftUI

extension FullScreenPlayerView {
    /// AetherEngine's host; never on visionOS, where the next engine plays.
    @ViewBuilder
    func aetherEngineView(for media: PlayableMedia) -> some View {
        #if os(visionOS)
            Color.black.onAppear(perform: engineFailedToStart).id(engineIdentity)
        #else
            AetherEngineEngineView(
                media: media, clock: clock, mediaSwapper: mediaSwapper,
                nextUpMedia: nextUpMedia, itemNeighbours: itemNeighbours, skipSegments: skipSegments,
                reportsStartupFailure: hasFallbackEngine, usesQuickStartupTimeout: hasFallbackEngine,
                onPlaybackFailed: engineFailedToStart, onSelectMedia: switchMedia,
                onCompleteCurrentItem: completeActiveEpisode, onRemoteAdvance: remoteAdvanceHandler,
                onCatchupSeek: handleCatchupSeek, refreshStreamURL: refreshedStreamURL,
                session: session, nowPlayingOwner: playbackLease
            )
            .id(engineIdentity)
        #endif
    }

    /// A Stalker link's short-lived URL, resolved again when the provider
    /// refused the current one; nil for streams whose URL doesn't expire.
    var refreshedStreamURL: (() async -> URL?)? {
        guard StalkerLink.isPlaceholder(activeMedia.url) else { return nil }
        let media = activeMedia
        let container = modelContext.container
        return { try? await StalkerStreamResolver.resolve(media, container: container).url }
    }
}
