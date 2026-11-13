//
//  AetherControlsOverlay.swift
//  Lume
//
//  Engine observation and scrubbing adapter for the shared standard overlay
//  (iOS, macOS); tvOS uses `TVPlayerControlsOverlay` directly.
//

#if !os(tvOS) && !os(visionOS)

    import SwiftUI

    struct AetherControlsOverlay: View {
        @ObservedObject var coordinator: AetherEngineCoordinator
        let media: PlayableMedia
        @Binding var isSeeking: Bool
        @Binding var seekPosition: TimeInterval
        /// Only the timeline leaf reads the clock, so ticks never re-render
        /// this body (and an open track menu with it).
        let clock: PlaybackClock
        var onSuspendHide: () -> Void
        var onClose: () -> Void
        var onTogglePlay: () -> Void
        var onResetHideTimer: () -> Void
        var onScheduleHide: () -> Void
        var itemNeighbours = PlayerItemNavigation.Neighbours.none
        var onStepItem: ((PlayerMediaSwapper.Step) -> Void)?
        var onSearchSubtitles: (() -> Void)?

        var body: some View {
            PlayerControlsOverlay(
                presentation: .init(
                    engine: .aetherEngine, isPlaying: coordinator.isPlaying,
                    videoInfo: coordinator.videoInfo,
                    audioTracks: coordinator.audioTrackOptions, textTracks: coordinator.textTrackOptions,
                    rate: coordinator.playbackRate,
                    isPipSupported: coordinator.isPipSupported, isPipActive: coordinator.isPipActive
                ),
                actions: .init(
                    close: onClose, togglePlay: onTogglePlay,
                    togglePip: coordinator.togglePictureInPicture,
                    resetHideTimer: onResetHideTimer,
                    skip: coordinator.skip,
                    selectAudioTrack: { coordinator.selectAudioTrack(id: $0) },
                    selectTextTrack: { coordinator.selectTextTrack(id: $0) },
                    setRate: { coordinator.playbackRate = $0 },
                    sliderEditingChanged: sliderEditingChanged,
                    searchSubtitles: onSearchSubtitles,
                    stepItem: onStepItem
                ),
                media: media, isSeeking: $isSeeking, seekPosition: $seekPosition,
                clock: clock, route: AirPlayRouteButton(),
                itemNeighbours: itemNeighbours
            )
        }

        private func sliderEditingChanged(_ editing: Bool) {
            isSeeking = editing
            if editing {
                onSuspendHide()
            } else {
                // Clock first: a catch-up seek re-places it on the segment.
                clock.current = seekPosition
                coordinator.seek(to: seekPosition)
                onScheduleHide()
            }
        }
    }

#endif
