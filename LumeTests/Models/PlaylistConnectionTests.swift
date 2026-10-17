import Foundation
@testable import Lume
import Testing

struct PlaylistConnectionTests {
    @Test func `unknown sources and non-network servers do not become Xtream`() {
        let playlist = Playlist(name: "Source", serverURL: "https://example.test", username: "user", password: "pass")
        playlist.sourceTypeRaw = "future-server"
        #expect(playlist.connection == nil)
        #expect(XtreamClient.buildMovieURL(for: Movie(id: "movie", streamId: 1, name: "Movie"), playlist: playlist) == nil)
        playlist.sourceType = .xtream
        playlist.serverURL = "file:///private/server"
        #expect(playlist.connection == nil)
        playlist.sourceType = .m3u
        #expect(playlist.connection?.sourceType == .m3u)
    }

    @Test func `source-specific authentication never uses unrelated stored columns`() {
        let playlist = Playlist(name: "Source", webdavURL: "https://example.test/share", username: "user", password: "pass")
        playlist.plexAccessToken = "old-plex-token"
        playlist.jellyfinAccessToken = "old-media-server-token"
        #expect(playlist.connection?.playbackHeaders == ["Authorization": "Basic dXNlcjpwYXNz"])
        playlist.sourceType = .plex
        #expect(playlist.connection?.playbackHeaders == ["X-Plex-Token": "old-plex-token"])
        playlist.sourceType = .xtream
        #expect(playlist.connection?.playbackHeaders == nil)
    }

    @Test func `xtream stream credentials are encoded as individual path components`() throws {
        let playlist = Playlist(name: "Source", serverURL: "https://example.test/panel/", username: "a/b", password: "p?#%")
        let movie = Movie(id: "movie", streamId: 42, name: "Movie", containerExtension: "mkv")
        let url = try #require(XtreamClient.buildMovieURL(for: movie, playlist: playlist))
        #expect(url.absoluteString == "https://example.test/panel/movie/a%2Fb/p%3F%23%25/42.mkv")
        #expect(url.query == nil && url.fragment == nil)
    }
}
