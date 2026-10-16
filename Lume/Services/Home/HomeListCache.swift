import CryptoKit
import Foundation

/// Only list membership is persisted: title text/artwork belongs to the
/// catalogue. Media kind is essential because movie/series TMDB IDs overlap.
nonisolated struct HomeListIdentity: Codable, Hashable {
    let id: Int
    let kind: HomeListEntry.MediaType

    init(_ entry: HomeListEntry) {
        id = entry.tmdbId
        kind = entry.mediaType
    }

    var entry: HomeListEntry {
        HomeListEntry(tmdbId: id, mediaType: kind, title: "")
    }
}

nonisolated struct HomeListCacheKey: Codable, Hashable {
    let source: String
    let account: String?
    let language: String

    init(source: String, account: String?, language: String = TMDBClient.preferredLanguageCode()) {
        self.source = HomeListCatalog.normalizedInputURL(source)?.absoluteString ?? source
        self.account = HomeListCatalog.provider(for: source) is TraktListProvider ? account : nil
        self.language = language
    }

    var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct HomeListCacheRecord: Codable, Equatable {
    let identities: [HomeListIdentity]
    let nextPage: Int?
    let fetchedAt: Date

    var entries: [HomeListEntry] {
        identities.map(\.entry)
    }
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
    private var records: [String: HomeListCacheRecord]?
    private var requests: [String: Task<HomeListPage, Error>] = [:]

    init(directory: URL = URL.cachesDirectory.appendingPathComponent("LumeListMembership", isDirectory: true), maximumSources: Int = 64) {
        url = directory.appendingPathComponent("membership-v1.json")
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
        guard !Task.isCancelled, page.entries.count <= Self.maximumEntries,
              page.entries.allSatisfy({ $0.tmdbId > 0 }),
              page.nextPage.map({ (2 ... 50).contains($0) }) ?? true
        else { return }
        loadIfNeeded()
        records?[key.digest] = HomeListCacheRecord(
            identities: page.entries.map(HomeListIdentity.init), nextPage: page.nextPage, fetchedAt: now
        )
        if let values = records, values.count > maximumSources {
            records = Dictionary(uniqueKeysWithValues: values.sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(maximumSources))
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
        let identity = "\(key.digest)|\(number)"
        if let task = requests[identity] { return try await task.value }
        let task = Task.detached(priority: .userInitiated) { try await fetch(key.source, number) }
        requests[identity] = task
        defer { requests[identity] = nil }
        return try await task.value
    }

    private func loadIfNeeded() {
        guard records == nil else { return }
        records = [:]
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: HomeListCacheRecord].self, from: data)
        else { return }
        records = Dictionary(uniqueKeysWithValues: decoded.filter {
            $0.value.identities.count <= Self.maximumEntries && $0.value.identities.allSatisfy { $0.id > 0 }
                && ($0.value.nextPage.map { (2 ... 50).contains($0) } ?? true)
        }.sorted { $0.value.fetchedAt > $1.value.fetchedAt }.prefix(maximumSources))
    }

    private func persist() {
        guard let records, let data = try? JSONEncoder().encode(records) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // Derived cache only. Keep the in-memory copy if tvOS purged disk
            // storage or the cache directory is temporarily unavailable.
        }
    }
}
