//
//  KSPlayerEngineView+TrackCarry.swift
//  Lume
//
//  Puts a subtitle pick carried from the last episode back on (see
//  `TrackCarryOver`). Audio needs no step here: the carried language leads
//  the stream's preferred languages, which KSPlayer applies as it opens.
//

import Combine
import KSPlayer
import SwiftUI

extension View {
    /// Applies the carried subtitle each time KSPlayer lists a stream's
    /// embedded subtitles — from none to some, so a side-loaded file added
    /// later never pulls the selection back.
    func carriesSubtitlePick(_ coordinator: KSVideoPlayer.Coordinator, from session: TrackCarryOverSession?) -> some View {
        modifier(KSSubtitleCarryModifier(coordinator: coordinator, session: session))
    }
}

private struct KSSubtitleCarryModifier: ViewModifier {
    let coordinator: KSVideoPlayer.Coordinator
    let session: TrackCarryOverSession?
    @State private var listed = false

    func body(content: Content) -> some View {
        content.onReceive(coordinator.subtitleModel.$subtitleInfos) { infos in
            let wasListed = listed
            listed = !infos.isEmpty
            guard let session, !wasListed, listed, session.carry.subtitle != nil else { return }
            // KSPlayer auto-selects in the same pass that publishes the list;
            // run after it, so an Off pick isn't selected over.
            DispatchQueue.main.async { coordinator.applyCarriedSubtitle(session.carry) }
        }
    }
}
