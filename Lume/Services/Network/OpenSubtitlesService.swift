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
        persistence: OpenSubtitlesPersistence = .live,
        cache: OpenSubtitlesCache = .live,
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.persistence = persistence
        self.cache = cache
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
            let newSession = try await client.login(username: trimmed, password: password, host: OpenSubtitlesClient.defaultHost)
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
        let permit = machine.generation
        let results = try await client.search(query, host: host, token: session?.token)
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
        guard let session else { throw OpenSubtitlesError.notAuthenticated }
        let permit = machine.generation

        let download = try await client.downloadLink(for: subtitle, session: session)
        try requireCurrent(permit)
        let data = try await client.fetch(download)
        try requireCurrent(permit)
        machine.recordDownload(download.remainingDownloads, permit: permit)
        Logger.player.info("OpenSubtitles: downloaded subtitle, \(download.remainingDownloads) left today")
        return try cache.store(data, subtitle)
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
