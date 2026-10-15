import Foundation
@testable import Lume
import Testing

struct PlaybackLocatorTests {
    @Test func `portal command and URL with the same storage text are different values`() throws {
        let value = "ffmpeg http://localhost/ch/1_"
        let command = try #require(PlaybackLocator(stored: value, source: .stalker, portalType: .itv))
        guard case .portal = command else { Issue.record("Expected portal command"); return }
        let decoded = try #require(StalkerLink.decode(#require(command.playerURL)))
        #expect(decoded.cmd == value && decoded.type == .itv)
        #expect(PlaybackLocator(stored: value, source: .m3u, portalType: .itv) == nil)
    }

    @Test(arguments: ["file:///tmp/video.mp4", "rtsp://example.test/live", "udp://239.1.1.1:1234", "https://example.test/live"])
    func `playback schemes remain supported`(_ raw: String) throws {
        let locator = try #require(PlaybackLocator(stored: raw, source: .m3u, portalType: .vod))
        #expect(locator.playerURL?.absoluteString == raw)
    }

    @Test func `relative paths and blank commands are not playable locators`() {
        #expect(PlaybackLocator(stored: "/video.mp4", source: .m3u, portalType: .vod) == nil)
        #expect(PlaybackLocator(stored: " ", source: .stalker, portalType: .vod) == nil)
    }

    @Test func `non Xtream sources never fall through to credential-built URLs`() {
        let playlist = Playlist(name: "M3U", serverURL: "https://example.test", username: "", password: "")
        playlist.sourceType = .m3u
        let movie = Movie(id: "m", streamId: 1, name: "Missing URL")
        let stream = LiveStream(id: "l", streamId: 1, name: "Missing URL")
        #expect(PlayableMedia.from(movie: movie, playlist: playlist) == nil)
        #expect(PlayableMedia.from(stream: stream, playlist: playlist) == nil)
    }
}
