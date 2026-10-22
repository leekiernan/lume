//
//  OpenSubtitlesService.swift
//  Lume
//
//  App-wide coordinator for the OpenSubtitles integration. Owns the user
//  session (sign in / restore / sign out), remembers the viewer's preferred
//  subtitle languages, and turns a picked search result into a local file the
//  playback engines can side-load.
//
//  A shared singleton because the player overlays reach it from four different
//  engine views that have no common environment injection point, and the
//  Settings pane observes the same instance.
//

import Foundation
import OSLog
import SwiftUI

@MainActor
@Observable
final class OpenSubtitlesService {
    static let shared = OpenSubtitlesService()

    /// The signed-in account name, or nil when the user hasn't signed in.
    var username: String? {
        machine.account?.session.username
    }

    /// Downloads left in today's allowance, as last reported by `/download`.
    /// `nil` until a download has been made this session.
    var remainingDownloads: Int? {
        machine.account?.remainingDownloads
    }

    /// The account's daily download allowance, from the sign-in response.
    var allowedDownloads: Int? {
        machine.account?.session.allowedDownloads
    }

    /// A human-readable failure from the last sign-in attempt, surfaced in the
    /// Settings pane. Cleared when a new attempt begins.
    var signInError: String? {
        machine.error
    }

    var isSigningIn: Bool {
        machine.isSigningIn
    }

    /// The languages the search sheet asks for, persisted across launches.
    /// Defaults to the app's own language, which is the one the viewer reads.
    var preferredLanguages: [String] {
        didSet {
            guard preferredLanguages != oldValue else { return }
            defaults.set(preferredLanguages, forKey: Self.languagesKey)
        }
    }

    private var machine = OpenSubtitlesSessionMachine()
    private var session: OpenSubtitlesSession? {
        machine.account?.session
    }

    private var cachedLanguages: [OpenSubtitlesLanguage] = []
    private let client: any OpenSubtitlesProviding
    private let persistence: OpenSubtitlesPersistence
    private let cache: OpenSubtitlesCache
    private let defaults: UserDefaults

    static let languagesKey = "openSubtitlesPreferredLanguages"

    init(
        client: any OpenSubtitlesProviding = OpenSubtitlesClient.shared,
        persistence: OpenSubtitlesPersistence? = nil,
        cache: OpenSubtitlesCache? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.persistence = persistence ?? .live
        self.cache = cache ?? .live
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Self.languagesKey)
        preferredLanguages = stored ?? Self.defaultLanguages()
    }

    /// Whether the build carries an API key at all. When false the whole
    /// integration hides rather than surfacing errors the user can't act on.
    var isConfigured: Bool {
        client.isConfigured
    }

    var isSignedIn: Bool {
        session != nil
    }

    /// Whether the in-player search should be offered for `media`. Live channels
    /// are excluded: OpenSubtitles indexes films and episodes, and a live stream
    /// has neither an id nor a stable title to match on.
    static func supportsSearch(for media: PlayableMedia, supportsExternalSubtitles: Bool = true) -> Bool {
        SubtitleSearchPolicy.canSearch(isLive: media.isLive, isConfigured: shared.isConfigured, supportsExternalSubtitles: supportsExternalSubtitles)
    }

    /// The app's UI language as an OpenSubtitles language code. OpenSubtitles
    /// keys on the bare language part (`de`, `pt-br`), so a full identifier like
    /// `de-DE` is trimmed back to its language code.
    static func defaultLanguages() -> [String] {
        let preferred = Locale.preferredLanguages.first ?? "en"
        let code = Locale(identifier: preferred).language.languageCode?.identifier ?? "en"
        return [code]
    }

    // MARK: - Session

    /// Restores a previously signed-in session at launch. Cheap — a keychain
    /// read, no network.
    func restore() {
        guard isConfigured else { return }
        guard !isSigningIn, !isSignedIn else { return }
        machine.restore(persistence.load())
    }

    func signIn(username enteredUsername: String, password: String) async {
        guard isConfigured, !isSigningIn else { return }
        let trimmed = enteredUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !password.isEmpty else { return }

        guard let request = machine.beginSignIn() else { return }

        do {
            var newSession = try await client.login(username: trimmed, password: password, host: OpenSubtitlesClient.defaultHost)
            newSession.password = password
            try Task.checkCancellation()
            guard machine.finishSignIn(request, session: newSession) else { return }
            persistence.save(newSession)
        } catch {
            machine.failSignIn(request, message: Task.isCancelled ? nil : OpenSubtitlesError.presentationMessage(for: error))
        }
    }

    func signOut() async {
        let previous = machine.signOut()
        persistence.clear()
        cache.clear()
        cachedLanguages = []
        if let previous {
            // Best-effort: the local session is dropped regardless.
            try? await client.logout(session: previous)
        }
    }

    // MARK: - Search

    /// Subtitle candidates for `query` in `preferredLanguages`, best-downloaded
    /// first. Works signed out — only downloading needs an account.
    func search(_ query: OpenSubtitlesQuery) async throws -> [OnlineSubtitle] {
        var query = query
        query.languages = preferredLanguages
        var permit = machine.generation
        let results: [OnlineSubtitle]
        do {
            results = try await withSession(permit) { try await self.client.search(query, host: $0.host, token: $0.token) }
        } catch OpenSubtitlesError.notAuthenticated {
            // Searching doesn't need an account, so signed out — or a session
            // that couldn't be renewed — searches anonymously. Ending an
            // expired session starts a new generation; the anonymous answer
            // belongs to that one.
            permit = machine.generation
            results = try await client.search(query, host: OpenSubtitlesClient.defaultHost, token: nil)
        }
        try requireCurrent(permit)
        return results.sorted { $0.downloadCount > $1.downloadCount }
    }

    /// The full language list for the search sheet's filter, fetched once per
    /// app run.
    func languages() async -> [OpenSubtitlesLanguage] {
        if !cachedLanguages.isEmpty { return cachedLanguages }
        let permit = machine.generation
        let fetched = await (try? client.languages(host: host)) ?? []
        guard !Task.isCancelled, machine.accepts(permit) else { return [] }
        cachedLanguages = fetched
        return cachedLanguages
    }

    // MARK: - Download

    /// Downloads `subtitle` and returns the local file the engines load. Cached
    /// on disk, so re-picking the same track inside a session costs nothing
    /// against the daily allowance.
    func download(_ subtitle: OnlineSubtitle) async throws -> URL {
        if let cached = cache.cachedFile(subtitle) { return cached }
        let permit = machine.generation
        let download = try await withSession(permit) { try await self.client.downloadLink(for: subtitle, session: $0) }
        try requireCurrent(permit)
        let data = try await client.fetch(download)
        try requireCurrent(permit)
        machine.recordDownload(download.remainingDownloads, permit: permit)
        Logger.player.info("OpenSubtitles: downloaded subtitle, \(download.remainingDownloads) left today")
        return try cache.store(data, subtitle)
    }

    /// Runs `request` with the current session. An expired token is renewed
    /// once from the stored credentials; when that isn't possible the session
    /// is dropped, so Settings stops claiming a sign-in the server no longer
    /// honours ("Sign in to download" while signed in).
    private func withSession<T>(_ permit: RequestToken, _ request: (OpenSubtitlesSession) async throws -> T) async throws -> T {
        guard let session else { throw OpenSubtitlesError.notAuthenticated }
        do {
            let result = try await Self.performRenewing(
                session: session,
                login: { try await self.client.login(username: $0, password: $1, host: OpenSubtitlesClient.defaultHost) },
                request: request
            )
            if let renewed = result.renewed, machine.renew(renewed, permit: permit) {
                persistence.save(renewed)
            }
            return result.value
        } catch OpenSubtitlesError.notAuthenticated {
            if machine.endExpiredSession(permit: permit) { persistence.clear() }
            throw OpenSubtitlesError.notAuthenticated
        }
    }

    /// `request` against `session`, retried once on a fresh token when the
    /// server rejects the stored one. Returns the renewed session, if any, for
    /// the caller to persist. Throws `.notAuthenticated` when the token can't
    /// be renewed: no stored password, or the account no longer accepts it.
    static func performRenewing<T>(
        session: OpenSubtitlesSession,
        login: (String, String) async throws -> OpenSubtitlesSession,
        request: (OpenSubtitlesSession) async throws -> T
    ) async throws -> (value: T, renewed: OpenSubtitlesSession?) {
        do {
            return try await (request(session), nil)
        } catch OpenSubtitlesError.notAuthenticated {
            guard let password = session.password else { throw OpenSubtitlesError.notAuthenticated }
            var renewed: OpenSubtitlesSession
            do {
                renewed = try await login(session.username, password)
            } catch OpenSubtitlesError.invalidCredentials {
                throw OpenSubtitlesError.notAuthenticated
            }
            renewed.password = password
            return try await (request(renewed), renewed)
        }
    }

    private func requireCurrent(_ permit: RequestToken) throws {
        try Task.checkCancellation()
        guard machine.accepts(permit) else { throw CancellationError() }
    }

    private var host: String {
        session?.host ?? OpenSubtitlesClient.defaultHost
    }
}

// MARK: - On-disk cache

/// Where downloaded subtitle files live: a folder in Caches, so the system can
/// evict them under pressure without stranding the app. Files are named by
/// subtitle id, which makes a re-pick of the same track a cache hit instead of
/// another download against the daily quota.
enum OnlineSubtitleCache {
    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("OpenSubtitles", isDirectory: true)
    }

    static func fileURL(for subtitle: OnlineSubtitle) -> URL {
        // The engines pick their parser from the path extension, so the `.srt`
        // suffix is load-bearing — `sub_format: "srt"` guarantees the content.
        directory.appendingPathComponent("\(subtitle.id).\(subtitle.languageCode).srt")
    }

    static func cachedFile(for subtitle: OnlineSubtitle) -> URL? {
        let url = fileURL(for: subtitle)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    static func store(_ data: Data, for subtitle: OnlineSubtitle) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: subtitle)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
