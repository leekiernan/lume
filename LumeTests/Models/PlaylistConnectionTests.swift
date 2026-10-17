import Foundation
@testable import Lume
import Testing

struct PlaylistConnectionTests {
    @Test func `unknown sources and non-network servers do not become Xtream`() {
        let playlist = Playlist(name: "Source", serverURL: "https://example.test", username: "user", password: "pass")
        playlist.sourceTypeRaw = "future-server"
        #expect(playlist.connection == nil)
        #expect(XtreamClient.playerAPIURL(for: playlist) == nil)
        #expect(XtreamClient.xmltvURL(for: playlist) == nil)
        #expect(XtreamClient.lumeCapabilitiesURL(for: playlist) == nil)
        #expect(LumeProxySource(playlist: playlist) == nil)
        #expect(XtreamClient.buildMovieURL(for: Movie(id: "movie", streamId: 1, name: "Movie"), playlist: playlist) == nil)
        playlist.sourceType = .xtream
        playlist.serverURL = "file:///private/server"
        #expect(playlist.connection == nil)
        playlist.sourceType = .m3u
        #expect(playlist.connection?.sourceType == .m3u)
    }

    @Test func `source-specific authentication never uses unrelated stored columns`() throws {
        let resource = try #require(URL(string: "https://example.test/resource"))
        let playlist = Playlist(name: "Source", webdavURL: "https://example.test/share", username: "user", password: "pass")
        playlist.plexAccessToken = "old-plex-token"
        playlist.jellyfinAccessToken = "old-media-server-token"
        #expect(playlist.connection?.playbackHeaders(for: resource) == ["Authorization": "Basic dXNlcjpwYXNz"])
        playlist.sourceType = .plex
        #expect(playlist.connection?.playbackHeaders(for: resource) == ["X-Plex-Token": "old-plex-token"])
        #expect(try playlist.connection?.playbackHeaders(for: #require(URL(string: "https://another.test/resource"))) == nil)
        playlist.sourceType = .xtream
        #expect(playlist.connection?.playbackHeaders(for: resource) == nil)
    }

    @Test func `xtream stream credentials are encoded as individual path components`() throws {
        let playlist = Playlist(name: "Source", serverURL: "https://example.test/panel", username: "a/b", password: "p?#%")
        let movie = Movie(id: "movie", streamId: 42, name: "Movie", containerExtension: "mkv")
        let url = try #require(XtreamClient.buildMovieURL(for: movie, playlist: playlist))
        #expect(url.absoluteString == "https://example.test/panel/movie/a%2Fb/p%3F%23%25/42.mkv")
        #expect(url.query == nil && url.fragment == nil)
    }

    @Test func `typed api assembly retains provider paths queries and credential encoding`() throws {
        let playlist = Playlist(name: "Source", serverURL: "https://example.test/panel?route=a&route=b", username: "a/b", password: "p?#%")
        let url = try #require(XtreamClient.playerAPIURL(for: playlist, action: "get_vod_info", parameters: [URLQueryItem(name: "vod_id", value: "42")]))
        #expect(url.path == "/panel/player_api.php")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items == [URLQueryItem(name: "route", value: "a"), URLQueryItem(name: "route", value: "b"),
                          URLQueryItem(name: "username", value: "a/b"), URLQueryItem(name: "password", value: "p?#%"),
                          URLQueryItem(name: "action", value: "get_vod_info"), URLQueryItem(name: "vod_id", value: "42")])
        playlist.sourceType = .plex
        #expect(XtreamClient.playerAPIURL(for: playlist) == nil)
        #expect(throws: StalkerError.self) { try StalkerClient.Configuration(playlist: playlist) }
    }
}
