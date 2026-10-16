//
//  TVPlayerControlsOverlay+Menus.swift
//  Lume
//
//  The tvOS controls' native menus: audio track, subtitles and Source (another
//  copy of what's playing — `PlayerSourceSwitch`). Each is
//  a `focus` target, so focus leaving them means a menu is open and the chrome
//  holds the controls up (`PlayerChromeMachine`).
//

import SwiftUI

#if os(tvOS)
    extension TVPlayerControlsOverlay {
        @ViewBuilder
        var audioTrackMenu: some View {
            let tracks = coordinator.audioTrackOptions
            if tracks.count > 1 {
                Menu {
                    ForEach(tracks) { track in
                        Button {
                            coordinator.selectAudioTrack(id: track.id)
                            onResetHideTimer()
                        } label: {
                            if track.isSelected {
                                Label(track.label, systemImage: "checkmark")
                            } else {
                                Text(track.label)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "waveform")
                }
                .menuIndicator(.hidden)
                .buttonStyle(TVPlayerCircleButtonStyle())
                .focused($focus, equals: .audio)
                .trackMenuAccessibility("Audio Track", selected: tracks.first(where: \.isSelected)?.label, fallback: "Default")
            }
        }

        @ViewBuilder
        var subtitleMenu: some View {
            let tracks = coordinator.textTrackOptions
            if !tracks.isEmpty || onSearchSubtitles != nil {
                Menu {
                    Button {
                        coordinator.selectTextTrack(id: nil)
                        onResetHideTimer()
                    } label: {
                        if !tracks.contains(where: \.isSelected) {
                            Label("Off", systemImage: "checkmark")
                        } else {
                            Text("Off")
                        }
                    }
                    ForEach(tracks) { track in
                        Button {
                            coordinator.selectTextTrack(id: track.id)
                            onResetHideTimer()
                        } label: {
                            if track.isSelected {
                                Label(track.label, systemImage: "checkmark")
                            } else {
                                Text(track.label)
                            }
                        }
                    }
                    if let onSearchSubtitles {
                        Button {
                            onSearchSubtitles()
                            onResetHideTimer()
                        } label: {
                            Label("Search Online…", systemImage: "magnifyingglass")
                        }
                    }
                } label: {
                    Image(systemName: "captions.bubble")
                }
                .menuIndicator(.hidden)
                .buttonStyle(TVPlayerCircleButtonStyle())
                .focused($focus, equals: .subtitles)
                .trackMenuAccessibility("Subtitles", selected: tracks.first(where: \.isSelected)?.label, fallback: "Off")
            }
        }

        /// Another playable copy, when the host found one.
        @ViewBuilder
        var sourceMenu: some View {
            if let remoteBridge, let sources = remoteBridge.sources {
                PlayerSourceMenu(sources: sources, bridge: remoteBridge, onChoose: onResetHideTimer) {
                    Image(systemName: "square.stack")
                }
                .buttonStyle(TVPlayerCircleButtonStyle())
                .focused($focus, equals: .source)
            }
        }
    }
#endif
