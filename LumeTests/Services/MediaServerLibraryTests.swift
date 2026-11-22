//
//  MediaServerLibraryTests.swift
//  LumeTests
//
//  Jellyfin/Emby servers with several libraries of one kind, read in parallel:
//  which library keeps a title both list, and a library that fails while the
//  others import. Uses `MediaServerSyncTests`' stub server and fixtures.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

extension MediaServerSyncTests {
    private func installTwoMovieLibraries(host: String, first: JellyfinServerStubProtocol.Reply, second: JellyfinServerStubProtocol.Reply) {
        JellyfinServerStubProtocol.install(host: host, replies: [
            "/Users/AuthenticateByName": .init(status: 200, body: """
            {"AccessToken": "sess", "User": {"Id": "user1"}}
            """),
            "/Users/user1/Views": .init(status: 200, body: """
            {"Items": [
              {"Id": "libA", "Name": "Films", "CollectionType": "movies"},
              {"Id": "libB", "Name": "Favourites", "CollectionType": "movies"}
            ], "TotalRecordCount": 2}
            """),
            "/Users/user1/Items|libA|Movie": first,
            "/Users/user1/Items|libB|Movie": second
        ])
    }

    @Test func `a title listed by two libraries stays with the one that holds it`() async throws {
        let host = uniqueHost()
        defer { JellyfinServerStubProtocol.remove(host: host) }
        let shared = jellyfinMovie(id: "m1", name: "Arrival")
        installTwoMovieLibraries(host: host, first: jellyfinPage([shared], total: 1), second: jellyfinPage([shared], total: 1))
        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host)
        let manager = makeManager(container: container)
        let prefix = playlist.id.uuidString

        try await manager.syncPlaylist(playlist)
        let first = try #require(try ModelContext(container).fetch(FetchDescriptor<Movie>()).first?.categoryId)
        #expect([prefix + "-vod-libA", prefix + "-vod-libB"].contains(first))

        for _ in 0 ..< 3 {
            try await manager.syncPlaylist(playlist)
            let movies = try ModelContext(container).fetch(FetchDescriptor<Movie>())
            #expect(movies.count == 1)
            #expect(movies.first?.categoryId == first, "parallel reads must not move it back and forth")
        }
    }

    @Test func `a library that fails is skipped, keeping its rows and the other library's import`() async throws {
        let host = uniqueHost()
        defer { JellyfinServerStubProtocol.remove(host: host) }
        installTwoMovieLibraries(host: host,
                                 first: jellyfinPage([jellyfinMovie(id: "m1", name: "Arrival")], total: 1),
                                 second: jellyfinPage([jellyfinMovie(id: "m2", name: "Contact")], total: 1))
        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host)
        let manager = makeManager(container: container)
        try await manager.syncPlaylist(playlist)

        // The second library now fails, and the first has a new title.
        JellyfinServerStubProtocol.setReply(host: host, key: "/Users/user1/Items|libB|Movie", reply: .init(status: 500, body: ""))
        JellyfinServerStubProtocol.setReply(host: host, key: "/Users/user1/Items|libA|Movie", reply: jellyfinPage([
            jellyfinMovie(id: "m1", name: "Arrival"), jellyfinMovie(id: "m3", name: "Sicario")
        ], total: 2))
        await #expect(throws: ProviderImportError.self) { try await manager.syncPlaylist(playlist) }

        let names = try Set(ModelContext(container).fetch(FetchDescriptor<Movie>()).map(\.name))
        #expect(names == ["Arrival", "Contact", "Sicario"], "the failed library's rows aren't pruned")
    }

    @Test func `a session the server stops accepting still ends the sync`() async throws {
        let host = uniqueHost()
        defer { JellyfinServerStubProtocol.remove(host: host) }
        installTwoMovieLibraries(host: host, first: .init(status: 401, body: ""), second: .init(status: 401, body: ""))
        let container = try makeTestContainer()
        let playlist = try makePlaylist(container: container, host: host)
        await #expect(throws: JellyfinError.self) { try await makeManager(container: container).syncPlaylist(playlist) }
    }
}
