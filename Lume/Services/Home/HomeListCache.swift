import CryptoKit
import Foundation

nonisolated struct HomeListCacheKey: Codable, Hashable {
    let source: String
    let account: String?
    let language: String

    init(source: String, account: String?, language: String = TMDBClient.preferredLanguageCode()) {
        self.source = HomeListCatalog.normalizedInputURL(source)?.absoluteString ?? source
        self.account = HomeListCatalog.provider(for: source) is TraktListProvider ? account : nil
        self.language = language
    }

    /// What the cache file stores in place of the key, so a list's URL and
    /// the Trakt account never sit in it in plain text.
    var digest: HomeListCacheDigest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(self)) ?? Data()
        return HomeListCacheDigest(rawValue: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}

/// Only list membership is kept: title text and artwork belong to the
/// catalogue. A `TMDBTitleReference` carries the media kind, which matters as
/// movie and series TMDB ids overlap.
nonisolated struct HomeListCacheRecord: Equatable {
    let titles: [TMDBTitleReference]
    let nextPage: Int?
    let fetchedAt: Date

    var entries: [HomeListEntry] {
        titles.map(HomeListEntry.init)
    }
}

/// A `HomeListCacheKey`'s SHA-256, hex-encoded: how a record is filed.
nonisolated struct HomeListCacheDigest: Hashable {
    let rawValue: String
}

/// The cache file's shape: scalars only, mapped to and from the typed values
/// at this boundary — the way the models keep `tmdbId` columns beside their
/// typed `tmdbIdentifier`. The file doesn't change when a domain type does.
private nonisolated struct StoredHomeListRecord: Codable {
    struct Title: Codable {
        let tmdbId: Int
        let kind: HomeListEntry.MediaType

        init(_ reference: TMDBTitleReference) {
            tmdbId = reference.rawValue
            kind = reference.kind == .movie ? .movie : .series
        }

        /// Nil for an id no TMDB title can have, so a damaged file drops it.
        var reference: TMDBTitleReference? {
            TMDBTitleReference(kind: kind == .movie ? .movie : .series, rawValue: tmdbId)
        }
    }

    let digest: String
    let titles: [Title]
    let nextPage: Int?
    let fetchedAt: Date

    init(_ record: HomeListCacheRecord, filedAs digest: HomeListCacheDigest) {
        self.digest = digest.rawValue
        titles = record.titles.map(Title.init)
        nextPage = record.nextPage
        fetchedAt = record.fetchedAt
    }

    /// The typed record, or nil when any title is invalid.
    var record: HomeListCacheRecord? {
        let references = titles.compactMap(\.reference)
        guard references.count == titles.count else { return nil }
        return HomeListCacheRecord(titles: references, nextPage: nextPage, fetchedAt: fetchedAt)
    }
}

/// One page of one source, so concurrent screens share the fetch.
private nonisolated struct HomeListPageRequest: Hashable {
    let source: HomeListCacheDigest
    let page: Int
}

/// Small device-local stale-while-revalidate cache. All disk access stays on
/// this actor, never the main actor. A cache failure never prevents browsing.
actor HomeListCache {
    static let shared = HomeListCache()
    static let lifetime: TimeInterval = 15 * 60
    private static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    private static let maximumEntries = 5000
    private let url: URL
    private let maximumSources: Int
    private var records: [HomeListCacheDigest: HomeListCacheRecord]?
    private var requests: [HomeListPageRequest: Task<HomeListPage, Error>] = [:]

    init(directory: URL = URL.cachesDirectory.appendingPathComponent("LumeListMembership", isDirectory: true), maximumSources: Int = 64) {
        url = directory.appendingPathComponent("membership-v2.json")
        self.maximumSources = max(maximumSources, 1)
    }

    func record(for key: HomeListCacheKey, now: Date = .now) -> HomeListCacheRecord? {
        loadIfNeeded()
        guard let record = records?[key.digest],
              record.fetchedAt <= now.addingTimeInterval(60),
              now.timeIntervalSince(record.fetchedAt) <= Self.maximumAge
        else { return nil }
        return record
    }

    func store(_ page: HomeListPage, for key: HomeListCacheKey, now: Date = .now) {
        let titles = page.entries.compactMap(\.reference)
        guard !Task.isCancelled, titles.count == page.entries.count, titles.count <= Self.maximumEntries,
              page.nextPage.map({ (2 ... 50).contains($0) }) ?? true
        else { return }
        loadIfNeeded()
        records?[key.digest] = HomeListCacheRecord(titles: titles, nextPage: page.nextPage, fetchedAt: now)
        if let values = records, values.count > maximumSources {
            records = newest(values)
        }
        persist()
    }

    func remove(_ key: HomeListCacheKey) {
        loadIfNeeded()
        records?[key.digest] = nil
        persist()
    }

    /// Home and Movies can ask for the same page together. Share that request;
    /// one disappearing screen must not cancel another screen's refresh.
    func page(for key: HomeListCacheKey, number: Int,
              fetch: @escaping @Sendable (String, Int) async throws -> HomeListPage) async throws -> HomeListPage
    {
        try Task.checkCancellation()
        let request = HomeListPageRequest(source: key.digest, page: number)
        if let task = requests[request] { return try await task.value }
        let task = Task.detached(priority: .userInitiated) { try await fetch(key.source, number) }
        requests[request] = task
        defer { requests[request] = nil }
        return try await task.value
    }

    private func loadIfNeeded() {
        guard records == nil else { return }
        records = [:]
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024,
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([StoredHomeListRecord].self, from: data)
        else { return }
        let valid = stored.compactMap { entry in
            entry.record.map { (HomeListCacheDigest(rawValue: entry.digest), $0) }
        }.filter { _, record in
            record.titles.count <= Self.maximumEntries && (record.nextPage.map { (2 ... 50).contains($0) } ?? true)
        }
        records = newest(Dictionary(valid, uniquingKeysWith: { first, _ in first }))
    }

    /// The `maximumSources` most recently fetched records.
    private func newest(_ records: [HomeListCacheDigest: HomeListCacheRecord]) -> [HomeListCacheDigest: HomeListCacheRecord] {
        let kept = records.sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(maximumSources)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private func persist() {
        guard let records,
              let data = try? JSONEncoder().encode(records.map { StoredHomeListRecord($0.value, filedAs: $0.key) })
        else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // Derived cache only. Keep the in-memory copy if tvOS purged disk
            // storage or the cache directory is temporarily unavailable.
        }
    }
}
