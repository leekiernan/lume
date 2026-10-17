import Foundation

/// Provider metadata may name a container, never a path. Legacy file stems
/// remain readable; new attempt suffixes have one exact UUID-shaped boundary.
nonisolated enum DownloadFileIdentity {
    static func safeExtension(_ value: String?) -> String {
        guard let value, (1 ... 12).contains(value.utf8.count),
              value.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) }) else { return "mp4" }
        return value.lowercased()
    }

    static func isBasename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    static func matches(_ file: URL, stem: String) -> Bool {
        stems(for: file).contains(stem)
    }

    static func stems(for file: URL) -> [String] {
        let base = file.deletingPathExtension().lastPathComponent
        guard let separator = base.lastIndex(of: "."), UUID(uuidString: String(base[base.index(after: separator)...])) != nil else { return [base] }
        return [base, String(base[..<separator])]
    }
}

extension DownloadManager {
    /// Whether the title has something to download. The download affordance
    /// asks this, not just the playlist, so an m3u entry whose stream is
    /// `rtmp:` or `file:` offers no button rather than one that does nothing.
    static func canDownload(_ movie: Movie, from playlist: Playlist) -> Bool {
        playlist.supportsDownloads && movieURL(movie, playlist: playlist) != nil
    }

    static func canDownload(_ episode: Episode, from playlist: Playlist) -> Bool {
        playlist.supportsDownloads && episodeURL(episode, playlist: playlist) != nil
    }

    static func movieURL(_ movie: Movie, playlist: Playlist) -> URL? {
        downloadURL(direct: movie.directURL, playlist: playlist) { XtreamClient.buildMovieURL(for: movie, playlist: playlist) }
    }

    static func episodeURL(_ episode: Episode, playlist: Playlist) -> URL? {
        downloadURL(direct: episode.directSource, playlist: playlist) { XtreamClient.buildEpisodeURL(for: episode, playlist: playlist) }
    }

    /// Background downloads support HTTP byte streams, not arbitrary schemes.
    static func downloadURL(direct: String?, playlist: Playlist, xtream: () -> URL?) -> URL? {
        let url: URL? = switch playlist.knownSourceType {
        case .m3u: direct.flatMap(URL.init(string:))
        case .xtream: xtream()
        case .stalker, .webdav, .jellyfin, .emby, .plex, nil: nil
        }
        guard let url, HTTPOrigin(url) != nil else { return nil }
        return url
    }

    nonisolated static func sanitize(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\0", with: "_")
    }
}
