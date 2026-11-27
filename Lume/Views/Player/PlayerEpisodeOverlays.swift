import OSLog
import SwiftUI

/// The episode affordances every engine host layers above its own controls:
/// Skip Intro / Skip Recap, the tvOS Next Episode button and auto-advance.
/// One IntroDB lookup drives them all, and one `EpisodeOverlayMachine` decides
/// which is showing — the buttons below only draw what it offers.
///
/// The engines differ only in how they seek and what they hand focus back to
/// afterwards, so that comes in as a closure.
struct PlayerEpisodeOverlays: View {
    /// Intro / recap / outro windows for the active episode (from IntroDB);
    /// `nil` when IntroDB knows nothing about it.
    let segments: IntroSegments?
    /// The episode queued after the current one; `nil` when there is nothing to
    /// play next.
    let nextUpMedia: PlayableMedia?
    /// The shared playback clock. Only `EpisodeZoneReporter` reads it, so a
    /// tick re-renders that leaf and nothing here.
    let clock: PlaybackClock
    /// Whether the engine's own controls overlay is currently showing. The
    /// button stays up either way, lifted above the controls while they show.
    let controlsVisible: Bool
    /// Seeks the underlying player to an absolute time, in seconds.
    let onSeek: (TimeInterval) -> Void
    let onSelectMedia: (PlayableMedia) -> Void

    @State private var machine = EpisodeOverlayMachine()
    @Environment(PlayerControlsBridge.self) private var controlsBridge: PlayerControlsBridge?

    @AppStorage(PlayerSettings.Playback.showSkipIntroButtonKey)
    private var showSkipIntroButton = PlayerSettings.Playback.showSkipIntroButtonDefault
    @AppStorage(PlayerSettings.Playback.showNextEpisodeButtonKey)
    private var showNextButton = PlayerSettings.Playback.showNextEpisodeButtonDefault
    @AppStorage(PlayerSettings.Playback.autoPlayNextKey)
    private var autoPlayNext = PlayerSettings.Playback.autoPlayNextDefault
    /// Next Episode and auto-advance are Premium; free users get neither,
    /// whatever the stored toggles say.
    @State private var premium = PremiumManager.shared

    #if os(tvOS)
        @FocusState private var buttonFocused: Bool
    #endif

    var body: some View {
        // Bottom-trailing: the reporter fills the stack, so a centred stack
        // would put the button in the middle of the picture.
        ZStack(alignment: .bottomTrailing) {
            EpisodeZoneReporter(clock: clock, segments: segments) { send(.zone($0)) }

            if let content = buttonContent {
                EpisodeOfferButton(content: content, remote: remote)
                    .padding(.bottom, lift)
                    .modifier(DrawnByControls(controlsVisible: controlsVisible))
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .allowsHitTesting(machine.activeOffer != nil)
        .animation(.easeInOut(duration: 0.25), value: machine.activeOffer)
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .onChange(of: config, initial: true) { _, config in send(.configure(config)) }
        .onChange(of: episodeKey) { _, _ in send(.reset) }
        .onChange(of: machine.activeOffer != nil, initial: true) { _, showing in
            controlsBridge?.episodeButtonShowing = showing
        }
        .onChange(of: buttonKey, initial: true) { controlsBridge?.episodeButton = buttonContent }
        .onDisappear {
            controlsBridge?.episodeButtonShowing = false
            controlsBridge?.episodeButton = nil
        }
        #if os(tvOS)
        .onChange(of: takesFocus, initial: true) { _, takes in
            // Over a bare picture the button holds the remote: when it
            // appears, and again whenever the controls go (the engine
            // leaves its tap-catcher alone while it shows). With the
            // controls up it is one more stop in their navigation.
            if takes { Task { @MainActor in buttonFocused = true } }
        }
        #endif
    }

    /// How the button answers the remote: focus, Menu dismisses it, and a
    /// direction over a bare picture raises the controls.
    private var remote: EpisodeButtonRemote {
        #if os(tvOS)
            EpisodeButtonRemote(
                focus: .own($buttonFocused),
                onDismiss: { send(.dismiss) },
                onMove: { direction in
                    if !controlsVisible {
                        controlsBridge?.requestControls(focus: PlayerSurfaceInput.controlsFocus(for: .init(direction)))
                    }
                }
            )
        #else
            EpisodeButtonRemote()
        #endif
    }

    /// How far the button rises to clear the controls while they show.
    private var lift: CGFloat {
        controlsVisible ? controlsBridge?.height ?? 0 : 0
    }

    #if os(tvOS)
        private var takesFocus: Bool {
            machine.activeOffer != nil && !controlsVisible
        }
    #endif

    private var config: EpisodeOverlayMachine.Config {
        #if os(tvOS)
            let nextButton = premium.isPremium && showNextButton
        #else
            // iOS / macOS / visionOS carry an always-available Next Episode
            // button in the transport row (`PlayerItemNavButton`); an
            // outro-armed second one would compete with it.
            let nextButton = false
        #endif
        return EpisodeOverlayMachine.Config(
            skipButton: showSkipIntroButton,
            nextButton: nextButton,
            autoAdvance: premium.isPremium && autoPlayNext,
            hasNextEpisode: nextUpMedia != nil
        )
    }

    /// Changes when a different episode's data arrives: its segments, or what
    /// follows it.
    private var episodeKey: EpisodeKey {
        EpisodeKey(segments: segments, nextID: nextUpMedia?.id)
    }

    private struct EpisodeKey: Equatable {
        let segments: IntroSegments?
        let nextID: String?
    }

    private func send(_ event: EpisodeOverlayMachine.Event) {
        let before = machine.state
        let effects = machine.handle(event)
        if machine.state != before {
            // Read here, not in `body`, so the journal line records no clock
            // dependency.
            let playhead = Int(clock.current)
            let controls = controlsVisible ? "controls up, lift \(Int(lift)) pt" : "controls hidden"
            Logger.player.info(
                "overlays: \(before.logName) → \(machine.state.logName) at \(playhead) s (\(controls, privacy: .public))"
            )
        }
        for effect in effects {
            switch effect {
            case let .seek(time):
                onSeek(time)
            case .playNext:
                if let nextUpMedia { onSelectMedia(nextUpMedia) }
            }
        }
    }

    /// The button on offer, or nil. Next Episode needs something to play.
    private var buttonContent: EpisodeButtonContent? {
        guard let offer = machine.activeOffer else { return nil }
        if offer == .nextEpisode, nextUpMedia == nil { return nil }
        return EpisodeButtonContent(
            offer: offer,
            nextUpMedia: nextUpMedia,
            clock: clock,
            outro: segments?.outro,
            activate: { send(.activate) },
            dismiss: { send(.dismiss) }
        )
    }

    /// Changes when the button on offer does.
    private var buttonKey: ButtonKey {
        ButtonKey(offer: machine.activeOffer, nextID: nextUpMedia?.id)
    }

    private struct ButtonKey: Equatable {
        let offer: EpisodeOverlayMachine.Offer?
        let nextID: String?
    }
}

/// An episode button on offer and what pressing or dismissing it does.
/// `PlayerEpisodeOverlays` draws it over a bare picture; the tvOS controls
/// draw the same content while they show.
struct EpisodeButtonContent {
    let offer: EpisodeOverlayMachine.Offer
    let nextUpMedia: PlayableMedia?
    let clock: PlaybackClock
    let outro: IntroSegments.Segment?
    let activate: () -> Void
    let dismiss: () -> Void
}

/// Draws `content` as the Skip Intro, Skip Recap or Next Episode button.
struct EpisodeOfferButton: View {
    let content: EpisodeButtonContent
    let remote: EpisodeButtonRemote

    var body: some View {
        switch content.offer {
        case .skipRecap:
            PlayerSkipIntroOverlay(label: "Skip Recap", remote: remote, onSkip: content.activate)
        case .skipIntro:
            PlayerSkipIntroOverlay(label: "Skip Intro", remote: remote, onSkip: content.activate)
        case .nextEpisode:
            if let nextUpMedia = content.nextUpMedia {
                PlayerNextUpOverlay(
                    nextMedia: nextUpMedia, clock: content.clock, outro: content.outro, remote: remote,
                    onPlayNext: content.activate
                )
            }
        }
    }
}

/// On tvOS the controls draw the button while they show, so this copy steps
/// aside: invisible and out of focus. Fading with the controls, the two read
/// as one button. Other platforms keep it.
private struct DrawnByControls: ViewModifier {
    let controlsVisible: Bool

    func body(content: Content) -> some View {
        #if os(tvOS)
            content
                .opacity(controlsVisible ? 0 : 1)
                .disabled(controlsVisible)
        #else
            content
        #endif
    }
}

/// Reads the ten-a-second `PlaybackClock` and reports only a change of
/// `EpisodeOverlayMachine.Zone` — a window boundary crossed by playback or
/// jumped by a seek. A leaf of its own, so the per-tick re-render stops here.
private struct EpisodeZoneReporter: View {
    let clock: PlaybackClock
    let segments: IntroSegments?
    let onChange: (EpisodeOverlayMachine.Zone) -> Void

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: zone, initial: true) { _, zone in onChange(zone) }
    }

    private var zone: EpisodeOverlayMachine.Zone {
        EpisodeOverlayMachine.zone(current: clock.current, duration: clock.duration, segments: segments)
    }
}

/// How an episode button answers the Siri Remote. Applied to the `Button`
/// itself, not its container, so a non-focusable part beside it (the Next
/// Episode countdown) stays out of focus. Empty off tvOS.
struct EpisodeButtonRemote {
    #if os(tvOS)
        /// The button's own flag over a bare picture, or the controls' focus
        /// while they draw it.
        enum Focus {
            case own(FocusState<Bool>.Binding)
            case controls(FocusState<TVPlayerFocus?>.Binding)
        }

        let focus: Focus
        let onDismiss: () -> Void
        let onMove: (MoveCommandDirection) -> Void
    #endif
}

extension View {
    @ViewBuilder
    func episodeButtonRemote(_ remote: EpisodeButtonRemote) -> some View {
        #if os(tvOS)
            switch remote.focus {
            case let .own(focus):
                focused(focus)
                    // Menu dismisses the button rather than closing the player.
                    .onExitCommand(perform: remote.onDismiss)
                    .tvRemoteMoveCommand(perform: remote.onMove)
            case let .controls(focus):
                focused(focus, equals: .episodeButton)
                    .onExitCommand(perform: remote.onDismiss)
                    .tvRemoteMoveCommand(perform: remote.onMove)
            }
        #else
            self
        #endif
    }
}
