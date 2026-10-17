import Foundation
@testable import Lume
import Testing

@MainActor
struct ProviderArtworkAccountTests {
    private let url = URL(string: "https://server.test/library/metadata/1/thumb/17")!

    @Test func `plex rotation changes transport but retains account scoped artwork`() throws {
        let playlist = Playlist(name: "Plex", plexURL: "https://server.test", username: "alice", accessToken: "old-secret")
        let before = try #require(ProviderArtworkAccount(playlist: playlist)?.request(for: url))
        playlist.plexAccessToken = "new-secret"
        let after = try #require(ProviderArtworkAccount(playlist: playlist)?.request(for: url))
        #expect(before.cacheIdentity == after.cacheIdentity)
        #expect(before.transportIdentity != after.transportIdentity)
        #expect(after.headers["X-Plex-Token"] == "new-secret")
        #expect(!ArtworkRequest.carriesCredentials(after.url))
        #expect(!after.cacheIdentity.contains("secret"))
    }

    @Test func `different accounts and playlists never share private artwork`() throws {
        let playlist = Playlist(name: "Plex", plexURL: "https://server.test", username: "alice", accessToken: "secret")
        let alice = try #require(ProviderArtworkAccount(playlist: playlist)?.request(for: url))
        playlist.username = "bob"
        let bob = try #require(ProviderArtworkAccount(playlist: playlist)?.request(for: url))
        #expect(alice.cacheIdentity != bob.cacheIdentity)
        #expect(alice.transportIdentity != bob.transportIdentity)
        let other = Playlist(name: "Other", plexURL: "https://server.test", username: "alice", accessToken: "secret")
        #expect(ProviderArtworkAccount(playlist: other)?.request(for: url)?.cacheIdentity != alice.cacheIdentity)
    }

    @Test func `legacy embedded tokens are replaced rather than used as credentials`() throws {
        let playlist = Playlist(name: "Plex", plexURL: "https://server.test", username: "alice", accessToken: "current")
        let legacy = URL(string: url.absoluteString + "?X-Plex-Token=obsolete&width=600")!
        let request = try #require(ProviderArtworkAccount(playlist: playlist)?.request(for: legacy))
        #expect(request.headers["X-Plex-Token"] == "current")
        #expect(!request.url.absoluteString.contains("obsolete"))
        #expect(request.url.query == "width=600")
    }

    @Test func `foreign artwork never receives the sources credential`() throws {
        let playlist = Playlist(name: "Plex", plexURL: "https://server.test", username: "alice", accessToken: "private")
        let external = try #require(URL(string: "https://cdn.test/poster.jpg"))
        let request = try #require(ProviderArtworkAccount(playlist: playlist)?.request(for: external))
        #expect(request.headers.isEmpty)
        #expect(request.cacheIdentity == external.absoluteString)
    }

    @Test func `jellyfin uses modern query authorization without persisting it in identity`() throws {
        let playlist = Playlist(name: "JF", mediaServerURL: "https://server.test", flavor: .jellyfin,
                                username: "alice", password: "password", accessToken: "old", userId: "user")
        let image = try #require(URL(string: "https://server.test/Items/1/Images/Primary?tag=a&maxWidth=600"))
        let before = try #require(ProviderArtworkAccount(playlist: playlist)?.request(for: image))
        playlist.jellyfinAccessToken = "new"
        let after = try #require(ProviderArtworkAccount(playlist: playlist)?.request(for: image))
        #expect(before.cacheIdentity == after.cacheIdentity)
        #expect(before.transportIdentity != after.transportIdentity)
        #expect(after.headers["X-Emby-Token"] == "new")
        #expect(after.url.query?.contains("ApiKey=new") == true)
        playlist.jellyfinUserId = "another-user"
        #expect(ProviderArtworkAccount(playlist: playlist)?.request(for: image)?.cacheIdentity != after.cacheIdentity)
    }

    @Test func `manual plex tokens without an account id retain conservative isolation`() throws {
        let playlist = Playlist(name: "Plex", plexURL: "https://server.test", accessToken: "alice")
        let before = try #require(ProviderArtworkAccount(playlist: playlist)?.request(for: url))
        playlist.plexAccessToken = "bob"
        #expect(ProviderArtworkAccount(playlist: playlist)?.request(for: url)?.cacheIdentity != before.cacheIdentity)
    }

    @Test func `missing media server credentials do not disable public artwork fallbacks`() throws {
        let playlist = Playlist(name: "JF", mediaServerURL: "https://server.test", flavor: .jellyfin,
                                username: "alice", password: "password", accessToken: "old", userId: "user")
        playlist.jellyfinAccessToken = nil
        let account = try #require(ProviderArtworkAccount(playlist: playlist))
        #expect(try account.request(for: #require(URL(string: "https://server.test/Items/1/Images/Primary"))) == nil)
        let publicImage = try #require(URL(string: "https://image.tmdb.org/t/p/w185/poster.jpg"))
        let request = try #require(account.request(for: publicImage))
        #expect(request.headers.isEmpty)
        #expect(request.cacheIdentity == publicImage.absoluteString)
        #expect(request.transportIdentity == request.cacheIdentity)
    }

    @Test func `a warm start playlist owner resolves the same account as a matched hero`() throws {
        let playlist = Playlist(name: "Plex", plexURL: "https://server.test", username: "alice", accessToken: "current")
        let account = try #require(ProviderArtworkAccount(playlist: playlist))
        let accounts = [playlist.id: account]
        let warm = try #require(ProviderArtworkAccounts.request(for: url, ownerID: playlist.id.uuidString, accounts: accounts))
        let itemID = MediaItemKey.movie(CatalogID.prefix(playlist.id, infix: "plex") + "1").description
        let matched = try #require(ProviderArtworkAccounts.request(for: url, ownerID: itemID, accounts: accounts))
        #expect(warm == matched)
        #expect(warm.headers["X-Plex-Token"] == "current")
        #expect(ProviderArtworkAccounts.request(for: url, ownerID: nil, accounts: accounts) == nil)
        #expect(ProviderArtworkAccounts.request(for: url, ownerID: UUID().uuidString, accounts: accounts) == nil)
    }
}
