//
//  TrackCarryOverSessionTests.swift
//  LumeTests
//
//  The player's carried picks: kept from episode to episode and through the
//  same stream again, dropped for a movie or a channel.
//

import Foundation
@testable import Lume
import Testing

@MainActor
struct TrackCarryOverSessionTests {
    private static let german = TrackCarryOver.Track(languageTag: "ger", label: "Deutsch")

    private func media(_ ref: PlayableMedia.ContentRef, kind: PlayableMedia.Kind = .vod) throws -> PlayableMedia {
        let id: String = switch ref {
        case let .movie(value), let .episode(value), let .live(value): value
        }
        return try PlayableMedia(
            id: id, url: #require(URL(string: "http://example.com/\(id).mkv")), title: id, subtitle: nil,
            posterURL: nil, kind: kind, startTime: 0, contentRef: ref
        )
    }

    @Test func `picks carry from one episode to the next`() throws {
        let session = TrackCarryOverSession()
        try session.begin(media(.episode("e1")))
        session.noteAudio(Self.german)
        session.noteSubtitle(.off)

        try session.begin(media(.episode("e2")))

        #expect(session.carry.audio == Self.german)
        #expect(session.carry.subtitle == .off)
    }

    @Test func `the same stream again keeps its picks however often it renders`() throws {
        let session = TrackCarryOverSession()
        let movie = try media(.movie("m1"))
        session.begin(movie)
        session.noteAudio(Self.german)

        session.begin(movie)
        session.begin(movie)

        #expect(session.carry.audio == Self.german)
    }

    @Test func `a movie or a channel starts from the preferences`() throws {
        let session = TrackCarryOverSession()
        try session.begin(media(.episode("e1")))
        session.noteSubtitle(.off)

        try session.begin(media(.movie("m1")))
        #expect(session.carry.isEmpty)

        session.noteAudio(Self.german)
        try session.begin(media(.live("c1"), kind: .live))
        #expect(session.carry.isEmpty)
    }
}
