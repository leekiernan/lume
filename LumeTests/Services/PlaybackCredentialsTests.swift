//
//  PlaybackCredentialsTests.swift
//  LumeTests
//
//  Where each engine gets a stream's credentials: in the URL they were issued
//  for, with `Authorization` left as a header only for AVFoundation. What the
//  engines then do across a redirect is `PlaybackRedirectContractTests`.
//

import Foundation
@testable import Lume
import Testing

struct PlaybackCredentialsTests {
    private let url = URL(string: "https://media.example/Videos/1/stream.mkv?static=true")!
    private let basic = ["Authorization": "Basic " + Data("viewer:pa:ss".utf8).base64EncodedString()]

    @Test func `basic credentials become userinfo for KSPlayer and VLC, sent first to FFmpeg`() {
        let ksPlayer = PlaybackCredentials.input(for: .ksPlayer, url: url, headers: basic)
        let parts = URLComponents(url: ksPlayer.url, resolvingAgainstBaseURL: false)
        #expect(parts?.user == "viewer" && parts?.password == "pa:ss")
        #expect(parts?.host == "media.example" && parts?.percentEncodedQuery == "static=true")
        #expect(ksPlayer.sendsBasicFirst)
        #expect(ksPlayer.avFoundationHeaders == basic)
        let vlc = PlaybackCredentials.input(for: .vlc, url: url, headers: basic)
        #expect(vlc.url == ksPlayer.url && vlc.avFoundationHeaders == nil && !vlc.sendsBasicFirst)
    }

    @Test func `AVPlayer keeps basic credentials in the header it drops across origins`() {
        let input = PlaybackCredentials.input(for: .avPlayer, url: url, headers: basic)
        #expect(input.url == url && input.avFoundationHeaders == basic)
    }

    @Test(arguments: [PlaybackCredentials.Engine.ksPlayer, .avPlayer, .vlc])
    func `media server tokens become query items for every engine`(engine: PlaybackCredentials.Engine) throws {
        let plex = PlaybackCredentials.input(for: engine, url: url, headers: PlexClient.playbackHeaders(token: "plex-token"))
        let plexQuery = try #require(URLComponents(url: plex.url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(plexQuery.contains(URLQueryItem(name: "X-Plex-Token", value: "plex-token")))
        #expect(plex.avFoundationHeaders == nil)

        let jellyfinHeaders = JellyfinClient.playbackHeaders(token: "jellyfin-token")
        let jellyfin = PlaybackCredentials.input(for: engine, url: url, headers: jellyfinHeaders)
        let jellyfinQuery = try #require(URLComponents(url: jellyfin.url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(jellyfinQuery.contains(URLQueryItem(name: "api_key", value: "jellyfin-token")))
        #expect(jellyfin.avFoundationHeaders == (engine == .vlc ? nil : jellyfinHeaders))
        #expect(!jellyfin.sendsBasicFirst)
    }

    @Test func `a stream without credentials is untouched`() {
        for engine in [PlaybackCredentials.Engine.ksPlayer, .avPlayer, .vlc] {
            #expect(PlaybackCredentials.input(for: engine, url: url, headers: nil)
                == .init(url: url, avFoundationHeaders: nil, sendsBasicFirst: false))
        }
    }
}
