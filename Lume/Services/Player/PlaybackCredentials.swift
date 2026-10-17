//
//  PlaybackCredentials.swift
//  Lume
//
//  How a stream's credentials reach each engine. `PlayableMedia.httpHeaders`
//  holds them only for the server's own origin (`playbackHeaders(for:)`), but
//  from there every engine runs its own HTTP and follows redirects itself.
//  `PlaybackRedirectContractTests` measured what each sends on: FFmpeg repeats
//  its custom headers to any redirect target — and to every other URL it
//  opens, HLS segments included; AVFoundation drops `Authorization` across
//  origins but keeps a custom header such as `X-Plex-Token`.
//
//  So a credential travels in the URL it was issued for, which a redirect's
//  `Location` replaces: a media-server token as a query item, WebDAV's Basic
//  pair as userinfo. The one header left is `Authorization` for AVFoundation,
//  which it was measured to drop. The URL is transient by the same contract
//  as `HTTPBasicCredentials`: built at the handoff, never stored back onto
//  the media, a deep link, a download or restoration state.
//

import Foundation

nonisolated enum PlaybackCredentials {
    enum Engine {
        /// KSPlayer: FFmpeg, and its own AVFoundation player, on one URL.
        case ksPlayer
        case avPlayer
        case vlc
    }

    struct Input: Equatable {
        /// The only credential FFmpeg gets: it would send headers to every
        /// URL it opens.
        let url: URL
        /// `AVURLAssetHTTPHeaderFieldsKey`: `Authorization` alone.
        let avFoundationHeaders: [String: String]?
        /// FFmpeg sends a URL's userinfo only after a 401 unless told it is
        /// Basic; set when the URL carries userinfo, to save the round trip.
        let sendsBasicFirst: Bool
    }

    static func input(for engine: Engine, url: URL, headers: [String: String]?) -> Input {
        let tokenURL = JellyfinPlaybackAuth.authenticatedURL(url, headers: headers)
            ?? PlexPlaybackAuth.authenticatedURL(url, headers: headers)
        let authorization = headers?["Authorization"].map { ["Authorization": $0] }
        switch engine {
        case .ksPlayer, .vlc:
            let basicURL = HTTPBasicCredentials.authenticatedURL(url, headers: headers)
            return Input(
                url: basicURL ?? tokenURL ?? url,
                avFoundationHeaders: engine == .ksPlayer ? authorization : nil,
                sendsBasicFirst: engine == .ksPlayer && basicURL != nil
            )
        case .avPlayer:
            return Input(url: tokenURL ?? url, avFoundationHeaders: authorization, sendsBasicFirst: false)
        }
    }
}
