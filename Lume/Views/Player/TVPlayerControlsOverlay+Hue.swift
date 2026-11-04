//
//  TVPlayerControlsOverlay+Hue.swift
//  Lume
//
//  The tvOS player's Philips Hue menu, in the trailing row. A level picked
//  here is the saved default; Off ends the session and restores the lamps.
//  Shown only with a paired bridge and a chosen entertainment area.
//

#if os(tvOS)

    import SwiftUI

    extension TVPlayerControlsOverlay {
        var hueButton: some View {
            TVPlayerHueButton(focus: $focus, onResetHideTimer: onResetHideTimer)
        }
    }

    private struct TVPlayerHueButton: View {
        var focus: FocusState<TVPlayerFocus?>.Binding
        var onResetHideTimer: () -> Void

        @Environment(\.hueSync) private var hueSync
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @AppStorage(PlayerSettings.Hue.enabledKey) private var isEnabled = PlayerSettings.Hue.enabledDefault
        @AppStorage(PlayerSettings.Hue.intensityKey) private var intensityRaw = PlayerSettings.Hue.intensityDefault.rawValue
        @State private var pendingSelection: HueIntensity?
        /// Read once per reveal: pairing happens in Settings, never mid-play.
        @State private var isSetUp = false

        /// Read through the stored values so the button re-renders when they change.
        private var selection: HueIntensity {
            _ = (isEnabled, intensityRaw)
            return PlayerSettings.Hue.selection()
        }

        var body: some View {
            Group {
                if isSetUp, let hueSync {
                    menu(hueSync)
                }
            }
            .task { isSetUp = hueSync?.isConfigured ?? false }
        }

        private func menu(_ hueSync: HueSyncController) -> some View {
            Group {
                Menu {
                    if let note = note(for: hueSync) {
                        Section {
                            options
                        } header: {
                            Text(note)
                        }
                    } else {
                        options
                    }
                } label: {
                    Image(systemName: "lightbulb.max")
                }
                .menuIndicator(.hidden)
                .buttonStyle(TVPlayerCircleButtonStyle())
                .focused(focus, equals: .hue)
                .trackMenuAccessibility("player.hue.title", selected: selection.settingsTitle, fallback: "settings.hue.intensity.off")
                .hueSensitivityNotice(isPresented: isNoticePresented) {
                    if let pendingSelection { apply(pendingSelection, to: hueSync) }
                    pendingSelection = nil
                } onCancel: {
                    pendingSelection = nil
                }
            }
        }

        private var options: some View {
            ForEach(HueIntensity.allCases, id: \.self) { level in
                Button {
                    choose(level)
                    onResetHideTimer()
                } label: {
                    if level == selection {
                        Label(level.settingsTitle, systemImage: "checkmark")
                    } else {
                        Text(level.settingsTitle)
                    }
                }
            }
        }

        private var isNoticePresented: Binding<Bool> {
            Binding(get: { pendingSelection != nil }, set: { if !$0 { pendingSelection = nil } })
        }

        private func choose(_ level: HueIntensity) {
            guard let hueSync else { return }
            if level != .off, !isEnabled, !PlayerSettings.Hue.lightSensitivityNoticeShown() {
                pendingSelection = level
                return
            }
            apply(level, to: hueSync)
        }

        private func apply(_ level: HueIntensity, to hueSync: HueSyncController) {
            PlayerSettings.Hue.setSelection(level)
            if level == .off {
                hueSync.suspend()
            } else {
                hueSync.startIfEligible(reduceMotion: reduceMotion)
            }
        }

        private func note(for hueSync: HueSyncController) -> String? {
            let state = hueSync.sourceUnavailableReason.map(HueSyncState.unavailable) ?? hueSync.state
            return switch state {
            case .unavailable(.unsupportedEngine):
                String(localized: "player.hue.unavailable.engine", defaultValue: "Unavailable with this player")
            case .unavailable(.unsupportedContent):
                String(localized: "player.hue.unavailable.content", defaultValue: "Unavailable for this video")
            case .areaInUse:
                String(localized: "player.hue.areaInUse", defaultValue: "In use by another app")
            case .idle, .connecting, .streaming, .error:
                nil
            }
        }
    }

#endif
