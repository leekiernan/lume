//
//  AetherEngineEngineView.swift
//  Lume
//
//  AetherEngine's full-screen host, built like the other engines': the video
//  surface, the shared controls (`TVPlayerControlsOverlay` on tvOS,
//  `AetherControlsOverlay` elsewhere), episode overlays, the loading and
//  failure indicators, and the remote. AetherEngine draws no subtitles of its
//  own, so `AetherSubtitleOverlay` sits above the picture.
//
//  Another title or catch-up segment arrives as a new `media` and is loaded
//  into the same engine in place: no remount, no stop.
//

#if !os(visionOS)

    import SwiftData
    import SwiftUI

    struct AetherEngineEngineView: View {
        let media: PlayableMedia
        /// Held as the `@Observable` object, never read in this body: binding
        /// its tick-driven values would re-render the controls every tick.
        @Bindable var clock: PlaybackClock
        let mediaSwapper: PlayerMediaSwapper
        var nextUpMedia: PlayableMedia?
        var itemNeighbours = PlayerItemNavigation.Neighbours.none
        var skipSegments: IntroSegments?
        /// An initial-load failure goes to `onPlaybackFailed` (the host picks
        /// the next engine) instead of this view's error overlay.
        var reportsStartupFailure = false
        var usesQuickStartupTimeout = false
        var onPlaybackFailed: (() -> Void)?
        var onSelectMedia: ((PlayableMedia) -> Void)?
        var onCompleteCurrentItem: (() -> Void)?
        /// What the lock screen's next/previous buttons play; nil on tvOS.
        var onRemoteAdvance: ((PlayerMediaSwapper.Step) -> Bool)?
        var onCatchupSeek: ((CatchupSeek) -> Void)?
        /// A fresh URL when the provider refused the current one (Stalker).
        var refreshStreamURL: (() async -> URL?)?
        var session: PlaybackSession?
        var nowPlayingOwner: ActivityLease?

        /// `@LazyState`, not `@State`: built once per view (see `LazyState`).
        @LazyState var coordinator = AetherEngineCoordinator()
        @State var chrome = PlayerChromeController()
        var isControlsVisible: Bool {
            chrome.isVisible
        }

        @Environment(PlayerControlsBridge.self) var remoteBridge: PlayerControlsBridge?
        @State var loadFailed = false
        @State var isCatchupSegmentLoading = false
        @State var isSeeking = false
        @State var seekPosition: TimeInterval = 0
        @State var isPanelOpen = false
        @State var panelCloseToken = 0
        /// Held here, not in the overlay: the overlay goes away when the
        /// controls hide and would take the sheet with it.
        @State var isSearchingSubtitles = false
        #if os(tvOS)
            @State var isChannelBrowserOpen = false
            @FocusState var catcherFocused: Bool
            @Environment(\.modelContext) var modelContext
            @Environment(\.contentRestriction) var restriction
        #endif

        @Environment(\.trackCarryOver) private var trackCarryOver
        @Environment(\.dismiss) private var dismiss
        @Environment(\.scenePhase) private var scenePhase

        private var drawsControls: Bool {
            PlayerChrome.drawsControls(
                requested: isControlsVisible, started: coordinator.hasStartedPlayback,
                catchupSegmentLoading: isCatchupSegmentLoading, failed: loadFailed
            )
        }

        var body: some View {
            engineBody.reportsPlayback(
                to: session, engine: .aetherEngine,
                // The overlay this view shows is the failure the session hears.
                report: .init(
                    started: coordinator.report.started, buffering: coordinator.report.buffering,
                    playing: coordinator.report.playing, failed: loadFailed
                ),
                failureOverlay: $loadFailed
            )
        }

        private var engineBody: some View {
            ZStack {
                Color.black.ignoresSafeArea()

                AetherEngineVideoSurface(videoView: coordinator.session?.videoView)
                    .ignoresSafeArea()

                AetherSubtitleOverlay(
                    cues: coordinator.subtitleCues,
                    videoSize: coordinator.videoInfo.map { CGSize(width: $0.width, height: $0.height) }
                )
                .ignoresSafeArea()

                tapCatcher.ignoresSafeArea()

                if drawsControls {
                    controlsOverlay
                        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                }

                PlayerEpisodeOverlays(
                    segments: skipSegments,
                    nextUpMedia: nextUpMedia,
                    clock: clock,
                    controlsVisible: isControlsVisible,
                    onSeek: { time in
                        coordinator.seek(to: time)
                        #if os(tvOS)
                            Task { @MainActor in catcherFocused = true }
                        #endif
                    },
                    onSelectMedia: { onSelectMedia?($0) }
                )

                #if os(tvOS)
                    if isChannelBrowserOpen { channelBrowser }
                #endif

                if coordinator.isBuffering, !loadFailed {
                    PlayerLoadingIndicator(opening: coordinator.hasStartedPlayback || isCatchupSegmentLoading ? nil : media)
                        .transition(.opacity)
                }

                if loadFailed {
                    PlayerErrorIndicator(title: media.title, onRetry: { retryPlayback() }, onClose: { closePlayer() })
                        .transition(.opacity)
                }
            }
            .subtitleSearch(isPresented: $isSearchingSubtitles, media: media) { subtitle in
                coordinator.loadExternalSubtitle(subtitle)
            }
            .preferredColorScheme(.dark)
            .hueFrameSource(coordinator)
            .onAppear(perform: start)
            .onDisappear {
                chrome.deactivate()
                NowPlayingService.shared.detachTransport(owner: coordinator, host: nowPlayingOwner)
                coordinator.tearDown()
            }
            .onChange(of: coordinator.isPlaying) { _, playing in
                clock.isPlaying = playing
                scheduleHide()
            }
            .onChange(of: coordinator.hasStartedPlayback) { _, started in
                if started { isCatchupSegmentLoading = false }
            }
            .onChange(of: scenePhase) { _, phase in
                if PlayerBackgrounding.shouldPause(for: phase, pipActive: coordinator.isPipActive) {
                    coordinator.pauseForBackground()
                }
            }
            .onChange(of: media) { oldMedia, newMedia in
                // Another title or segment: loaded into the same engine.
                isSeeking = false
                seekPosition = 0
                isPanelOpen = false
                loadFailed = false
                isCatchupSegmentLoading = PlayerChrome.keepsCatchupControls(
                    previous: oldMedia.catchup, next: newMedia.catchup,
                    started: coordinator.hasStartedPlayback, alreadyLoading: isCatchupSegmentLoading
                )
                coordinator.configure(media: newMedia)
                scheduleHide()
            }
            #if os(tvOS)
            .episodeButtonFocusHandoff(
                controlsVisible: isControlsVisible, catcherFocused: $catcherFocused,
                showControls: { chrome.show(focus: $0, mayHide: { canAutoHideControls }) }
            )
            #endif
            .playerRemoteControls(controlsVisible: isControlsVisible, onBack: handleMenuPress, onPlayPause: togglePlay)
            #if os(macOS)
                .playerPointerChrome(chrome, mayHide: { canAutoHideControls })
            #endif
                .playerKeyboardShortcuts(PlayerKeyActions(
                    togglePlay: togglePlay, skip: { coordinator.skip(by: $0) }, skipInterval: media.skipInterval(default: 15),
                    close: closePlayer, resetHideTimer: scheduleHide,
                    neighbours: itemNeighbours, swapper: mediaSwapper, selectMedia: { onSelectMedia?($0) }
                ))
        }

        private func start() {
            chrome.activate()
            let catchup = coordinator.catchup
            coordinator.onTime = { current, duration in
                if !isSeeking { catchup.report(position: current, to: clock) }
                catchup.report(duration: duration, to: clock)
            }
            catchup.onSeek = onCatchupSeek
            coordinator.onPlaybackFailure = { reportFailure(allowsNextEngine: $0) }
            coordinator.resolveFreshURL = refreshStreamURL
            coordinator.trackCarryOver = trackCarryOver
            #if os(iOS)
                coordinator.onPictureInPictureStop = {
                    PlayerBackgrounding.pictureInPictureDidStop(owner: nowPlayingOwner, engineOwner: coordinator) { closePlayer() }
                }
            #endif
            coordinator.startupTimeout = PlaybackPolicy.startupTimeout(quick: usesQuickStartupTimeout)
            coordinator.retriesStartupErrors = PlaybackPolicy.retriesStartupError(canFallBack: reportsStartupFailure)
            coordinator.configure(media: media)
            NowPlayingService.shared.attachTransport(
                .driving(coordinator, advance: onRemoteAdvance), owner: coordinator, host: nowPlayingOwner
            )
            scheduleHide()
        }

        // MARK: Tap catcher and controls

        @ViewBuilder
        private var tapCatcher: some View {
            #if os(tvOS)
                PlayerTapCatcher(
                    isLive: media.isLive, controlsDrawn: drawsControls,
                    browserOpen: isChannelBrowserOpen, failed: loadFailed,
                    focused: $catcherFocused,
                    showControls: { chrome.show(focus: $0, mayHide: { canAutoHideControls }) },
                    openBrowser: openChannelBrowser, surf: switchLiveChannel
                )
            #else
                PlayerTapCatcher(toggleControls: { chrome.toggle(mayHide: { canAutoHideControls }) })
            #endif
        }

        @ViewBuilder
        private var controlsOverlay: some View {
            #if os(tvOS)
                TVPlayerControlsOverlay(
                    coordinator: coordinator,
                    media: media,
                    clock: clock,
                    panelCloseToken: panelCloseToken,
                    initialFocus: chrome.initialFocus,
                    onTogglePlay: { togglePlay() },
                    onResetHideTimer: { scheduleHide() },
                    onSelectMedia: { onSelectMedia?($0) },
                    onPanelOpenChange: { setPanelOpen($0) },
                    onMenuOpenChange: { chrome.menuChanged(isOpen: $0, mayHide: { canAutoHideControls }) },
                    onSwitchChannel: { switchLiveChannel($0) },
                    mediaSwapper: mediaSwapper, onCompleteCurrentItem: { onCompleteCurrentItem?() },
                    onSearchSubtitles: subtitleSearchAction
                )
            #else
                AetherControlsOverlay(
                    coordinator: coordinator,
                    media: media,
                    isSeeking: $isSeeking,
                    seekPosition: $seekPosition,
                    clock: clock,
                    onSuspendHide: { chrome.suspend() },
                    onClose: { closePlayer() },
                    onTogglePlay: { togglePlay() },
                    onResetHideTimer: { scheduleHide() },
                    onScheduleHide: { scheduleHide() },
                    itemNeighbours: itemNeighbours,
                    onStepItem: { stepItem($0) },
                    onSearchSubtitles: subtitleSearchAction
                )
            #endif
        }

        /// The OpenSubtitles browser, or nil when this stream can't use it.
        private var subtitleSearchAction: (() -> Void)? {
            coordinator.subtitleSearchAction(for: media, isPresented: $isSearchingSubtitles)
        }

        // MARK: Actions

        func togglePlay() {
            coordinator.togglePlay()
            scheduleHide()
        }

        func scheduleHide() {
            chrome.schedule(mayHide: { canAutoHideControls })
        }

        var canAutoHideControls: Bool {
            #if os(tvOS)
                let browserOpen = isChannelBrowserOpen
            #else
                let browserOpen = false
            #endif
            return PlayerControlsAutoHide.mayHide(
                isPlaying: coordinator.isPlaying,
                isPanelOpen: isPanelOpen || browserOpen || isSeeking,
                isSuppressed: PlayerControlsAutoHide.isSuppressed
            )
        }

        private func setPanelOpen(_ open: Bool) {
            isPanelOpen = open
            chrome.panelChanged(isOpen: open, mayHide: { canAutoHideControls })
        }

        /// Close the channel browser or an open panel first, then hide the
        /// controls, and only dismiss the player once they are hidden.
        private func handleMenuPress() {
            #if os(tvOS)
                let browserOpen = isChannelBrowserOpen
                let closeBrowser = closeChannelBrowser
            #else
                let browserOpen = false
                let closeBrowser = {}
            #endif
            chrome.menu(
                .init(failed: loadFailed, browserOpen: browserOpen, panelOpen: isPanelOpen),
                claimsBack: { remoteBridge?.claimsBack() == true }, closeBrowser: closeBrowser,
                closePanel: { panelCloseToken += 1 }, closePlayer: closePlayer
            )
        }

        func closePlayer() {
            #if os(macOS)
                MacPlayerWindowRouter.shared.close()
            #else
                dismiss.dismissPlayer()
            #endif
        }

        /// A stream that never played goes to the host when another engine is
        /// left; a stream that is gone, or a drop whose reconnects ran out,
        /// raises the overlay.
        private func reportFailure(allowsNextEngine: Bool) {
            guard !loadFailed else { return }
            isCatchupSegmentLoading = false
            if allowsNextEngine, reportsStartupFailure, !coordinator.hasStartedPlayback {
                onPlaybackFailed?()
                return
            }
            withAnimation(.easeInOut(duration: 0.25)) { loadFailed = true }
        }

        private func retryPlayback() {
            isCatchupSegmentLoading = false
            withAnimation(.easeInOut(duration: 0.25)) { loadFailed = false }
            coordinator.retryAfterFailure()
        }
    }

#endif
