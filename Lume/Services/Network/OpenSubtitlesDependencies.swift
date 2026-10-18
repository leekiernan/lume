import Foundation

@MainActor
protocol OpenSubtitlesProviding {
    var isConfigured: Bool { get }
    func login(username: String, password: String, host: String) async throws -> OpenSubtitlesSession
    func logout(session: OpenSubtitlesSession) async throws
    func search(_ query: OpenSubtitlesQuery, host: String, token: String?) async throws -> [OnlineSubtitle]
    func languages(host: String) async throws -> [OpenSubtitlesLanguage]
    func downloadLink(for subtitle: OnlineSubtitle, session: OpenSubtitlesSession) async throws -> OpenSubtitlesDownload
    func fetch(_ download: OpenSubtitlesDownload) async throws -> Data
}

nonisolated extension OpenSubtitlesClient: OpenSubtitlesProviding {}

/// Small persistence boundaries keep lifecycle tests away from the household's
/// keychain, defaults and subtitle files.
struct OpenSubtitlesPersistence {
    var load: () -> OpenSubtitlesSession?
    var save: (OpenSubtitlesSession) -> Void
    var clear: () -> Void

    static let live = Self(
        load: { OpenSubtitlesSessionStore.load() },
        save: { OpenSubtitlesSessionStore.save($0) },
        clear: { OpenSubtitlesSessionStore.clear() }
    )
}

struct OpenSubtitlesCache {
    var cachedFile: (OnlineSubtitle) -> URL?
    var store: (Data, OnlineSubtitle) throws -> URL
    var clear: () -> Void

    static let live = Self(
        cachedFile: { OnlineSubtitleCache.cachedFile(for: $0) },
        store: { try OnlineSubtitleCache.store($0, for: $1) },
        clear: { OnlineSubtitleCache.clear() }
    )
}
