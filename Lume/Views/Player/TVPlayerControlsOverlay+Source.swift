//
//  TVPlayerControlsOverlay+Source.swift
//  Lume
//
//  The tvOS controls' Source menu: another copy of what's playing, at the
//  same moment (`PlayerSourceSwitch`). Split out to keep the overlay within
//  the file-length limit.
//

import SwiftUI

#if os(tvOS)
    extension TVPlayerControlsOverlay {
        /// Another copy at the same moment, when the host found one.
        @ViewBuilder
        var sourceMenu: some View {
            if let remoteBridge, let sources = remoteBridge.sources {
                PlayerSourceMenu(sources: sources, bridge: remoteBridge, onChoose: onResetHideTimer) {
                    Image(systemName: "square.stack")
                }
                .buttonStyle(TVPlayerCircleButtonStyle())
            }
        }
    }
#endif
