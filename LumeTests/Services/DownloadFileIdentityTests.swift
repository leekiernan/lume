import Foundation
@testable import Lume
import Testing

struct DownloadFileIdentityTests {
    @Test(arguments: ["../Library/data", "mp4/../../Library/data", "mkv\\..\\data", ".mp4", "", "\0"])
    func `container metadata cannot inject a path`(value: String) {
        #expect(DownloadFileIdentity.safeExtension(value) == "mp4")
    }

    @Test func `ordinary container extensions are retained`() {
        #expect(DownloadFileIdentity.safeExtension("MKV") == "mkv")
        #expect(DownloadFileIdentity.safeExtension("m4v") == "m4v")
        #expect(DownloadFileIdentity.safeExtension(nil) == "mp4")
    }

    @Test func `task descriptions cannot restore an arbitrary destination path`() {
        for filename in ["../Library/private", "/tmp/file.mp4", ".", "..", "bad\\file.mp4"] {
            let info = DownloadTaskInfo(id: "movie", title: "Fixture", filename: filename)
            #expect(DownloadTaskInfo(taskDescription: info.taskDescription) == nil)
        }
    }

    @Test func `a dotted sibling filename is not another titles attempt`() {
        let sibling = URL(fileURLWithPath: "/tmp/movie.other.mp4")
        #expect(!DownloadFileIdentity.matches(sibling, stem: "movie"))
        let attempt = URL(fileURLWithPath: "/tmp/movie.\(UUID().uuidString).mp4")
        #expect(DownloadFileIdentity.matches(attempt, stem: "movie"))
    }

    @MainActor
    @Test(arguments: ["file:///private/data", "ftp://server.test/movie.mp4", "data:video/mp4,fixture"])
    func `download URLs cannot read arbitrary local or non-HTTP resources`(address: String) {
        let playlist = Playlist(name: "M3U", m3uURL: "https://server.test/list")
        #expect(DownloadManager.downloadURL(direct: address, playlist: playlist, xtream: { nil }) == nil)
    }

    @MainActor
    @Test(arguments: [("rtmp://server.test/movie", false), ("https://server.test/movie.mp4", true)])
    func `only a title with an HTTP stream offers a download`(address: String, offered: Bool) {
        let playlist = Playlist(name: "M3U", m3uURL: "https://server.test/list")
        let movie = Movie(id: "\(playlist.id.uuidString)-movie-1", streamId: 1, name: "Film")
        movie.directURL = address
        #expect(DownloadManager.canDownload(movie, from: playlist) == offered)
    }
}
