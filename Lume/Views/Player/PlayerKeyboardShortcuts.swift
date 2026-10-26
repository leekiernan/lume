//
//  PlayerKeyboardShortcuts.swift
//  Lume
//
//  The full-screen player's hardware-keyboard shortcuts, on the Mac and on
//  iPad with a keyboard: Space plays or pauses, Left/Right skip, Up/Down step
//  the live channel and Esc closes; F toggles full screen on the Mac.
//
//  `onKeyPress` only hears presses on the focused view's chain, and nothing in
//  the player took keyboard focus by itself — buttons don't without Full
//  Keyboard Access — so every shortcut the engine views declared was silently
//  dropped. One modifier now makes the engine view focusable, without a focus
//  ring, and handles every key. After upstream cf0f5cdb, without its volume
//  keys: lume has no app-level volume, so Up/Down stay with the channel.
//

import SwiftUI
#if canImport(AppKit)
    import AppKit
#endif

/// What a key press in the full-screen player asks for, if anything.
nonisolated enum PlayerKeyCommand: Equatable {
    case togglePlay
    case skipBackward
    case skipForward
    case nextChannel
    case previousChannel
    case toggleFullScreen
    case close

    private static let bindings: [KeyEquivalent: PlayerKeyCommand] = [
        .space: .togglePlay,
        .leftArrow: .skipBackward,
        .rightArrow: .skipForward,
        .upArrow: .nextChannel,
        .downArrow: .previousChannel,
        "f": .toggleFullScreen,
        .escape: .close
    ]

    /// Bare keys only: a chord (Cmd+Left, Shift+Space…) belongs to the system
    /// or the menu bar. Caps Lock and the numeric-pad and function flags AppKit
    /// stamps on arrow keys don't make a chord.
    init?(key: KeyEquivalent, modifiers: EventModifiers) {
        guard modifiers.isDisjoint(with: [.command, .option, .control, .shift]) else { return nil }
        // Caps Lock reports letters in upper case.
        let key = key.character.lowercased().first.map { KeyEquivalent($0) } ?? key
        guard let command = Self.bindings[key] else { return nil }
        self = command
    }

    /// Whether holding the key keeps acting at the key-repeat rate. A held
    /// toggle would flip back and forth.
    var repeats: Bool {
        switch self {
        case .skipBackward, .skipForward, .nextChannel, .previousChannel: true
        case .togglePlay, .toggleFullScreen, .close: false
        }
    }
}

/// What an engine view hands the shortcuts to drive.
struct PlayerKeyActions {
    var togglePlay: () -> Void
    var skip: (TimeInterval) -> Void
    var skipInterval: TimeInterval
    var close: () -> Void
    /// Keeps visible controls up after a transport key, as a click would.
    var resetHideTimer: () -> Void
    var neighbours: PlayerItemNavigation.Neighbours
    var swapper: PlayerMediaSwapper
    var selectMedia: (PlayableMedia) -> Void
}

extension View {
    /// Applied once per engine view. Does nothing on tvOS, where the Siri
    /// Remote has its own handling, or on visionOS.
    @ViewBuilder
    func playerKeyboardShortcuts(_ actions: PlayerKeyActions) -> some View {
        #if os(macOS) || os(iOS)
            modifier(PlayerKeyboardShortcuts(actions: actions))
        #else
            self
        #endif
    }
}

#if os(macOS) || os(iOS)
    private struct PlayerKeyboardShortcuts: ViewModifier {
        let actions: PlayerKeyActions
        @FocusState private var isFocused: Bool

        func body(content: Content) -> some View {
            content
                .focusable()
                .focusEffectDisabled()
                .focused($isFocused)
                .onAppear { isFocused = true }
                .onKeyPress(phases: [.down, .repeat]) { press in
                    guard let command = PlayerKeyCommand(key: press.key, modifiers: press.modifiers) else {
                        return .ignored
                    }
                    guard press.phase == .down || command.repeats else { return .handled }
                    return perform(command)
                }
        }

        private func perform(_ command: PlayerKeyCommand) -> KeyPress.Result {
            switch command {
            case .togglePlay:
                actions.togglePlay()
            case .skipBackward:
                actions.skip(-actions.skipInterval)
            case .skipForward:
                actions.skip(actions.skipInterval)
            case .nextChannel, .previousChannel:
                return stepChannel(command == .nextChannel ? .next : .previous)
            case .toggleFullScreen:
                return toggleFullScreen()
            case .close:
                actions.close()
                return .handled
            }
            actions.resetHideTimer()
            return .handled
        }

        /// Live TV only: `.channel` is the axis a live stream (and not a
        /// catch-up recording) carries, so during a film or an episode the
        /// press is left to the responder chain rather than silently stepping
        /// the series. Over live TV it is consumed whether or not the swapper's
        /// debounce let it through, so focus never leaves the video.
        private func stepChannel(_ step: PlayerMediaSwapper.Step) -> KeyPress.Result {
            guard actions.neighbours.axis == .channel else { return .ignored }
            actions.swapper.step(step, in: actions.neighbours, select: actions.selectMedia)
            actions.resetHideTimer()
            return .handled
        }

        private func toggleFullScreen() -> KeyPress.Result {
            #if os(macOS)
                guard let window = NSApp.keyWindow else { return .ignored }
                window.toggleFullScreen(nil)
                return .handled
            #else
                return .ignored
            #endif
        }
    }
#endif
