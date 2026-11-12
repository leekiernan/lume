//
//  TrackCarryOverSession.swift
//  Lume
//
//  Where the full-screen player keeps the viewer's hand-picked audio and
//  subtitle tracks (`TrackCarryOver`) between streams. The engine view is
//  rebuilt for every title (`FullScreenPlayerView.titleRemountCount`), so the
//  picks can't live on its coordinator; the player owns one of these for its
//  whole life and hands it down through the environment.
//
//  Plain, not observed: nothing draws from it, and the engine view starts each
//  stream with it from inside its body (`makeOptions`), where an observable
//  write would be a state change during a view update.
//

import SwiftUI

final class TrackCarryOverSession {
    private(set) var carry = TrackCarryOver()
    private var current: PlayableMedia?

    /// A stream is starting. Picks carry into the same stream again or the
    /// next episode; anything else starts from the viewer's preferences.
    /// Called once per render of the engine view, so the same stream again
    /// changes nothing.
    func begin(_ media: PlayableMedia) {
        guard current?.id != media.id || current?.url != media.url else { return }
        if !TrackCarryOver.carries(from: current, to: media) {
            carry = TrackCarryOver()
        }
        current = media
    }

    func noteAudio(_ track: TrackCarryOver.Track) {
        carry.audio = track
    }

    func noteSubtitle(_ subtitle: TrackCarryOver.Subtitle) {
        carry.subtitle = subtitle
    }
}

extension EnvironmentValues {
    /// Set by the full-screen player; Multi-View tiles and previews have none.
    @Entry var trackCarryOver: TrackCarryOverSession?
}
