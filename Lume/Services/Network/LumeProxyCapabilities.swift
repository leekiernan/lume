import CryptoKit
import Foundation
import OSLog
import SwiftData

/// Availability only. Even a supported metadata endpoint cannot certify that
/// a title's details/artwork/ratings have been applied to the local catalogue.
nonisolated struct LumeProxyCapabilities: Decodable, Equatable {
    let version: Int
    let metadata: LumeProxyMetadataCapability?
    let sports: LumeProxySportsCapability?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case metadata, sports
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        // A malformed/unknown optional feature must not enable that route or
        // break unrelated features of an otherwise recognised envelope.
        metadata = try? container.decode(LumeProxyMetadataCapability.self, forKey: .metadata)
        sports = try? container.decode(LumeProxySportsCapability.self, forKey: .sports)
    }

    var metadataBatchSize: Int? {
        guard version == 1, let metadata, metadata.version == 1, metadata.maxBatchSize > 0 else { return nil }
        return min(metadata.maxBatchSize, 50)
    }

    /// Whether batch items may carry MDBList ratings. Only an advertised group
    /// is read; a stray `mdblist` block from another producer is ignored.
    var offersRatings: Bool {
        metadataBatchSize != nil && metadata?.groups?.contains("ratings") == true
    }

    var sportsBatchSize: Int? {
        guard version == 1, let sports, sports.version == 1, sports.matcherVersion == 3,
              sports.source == "espn", sports.groups.contains("broadcasts"), sports.maxBatchSize > 0 else { return nil }
        return min(sports.maxBatchSize, 50)
    }
}

/// Independently negotiated: a sports-only proxy need not offer title metadata.
nonisolated struct LumeProxySportsCapability: Decodable, Equatable {
    let version: Int
    let matcherVersion: Int
    let source: String
    let competitions: [String]
    let maxBatchSize: Int
    let groups: [String]

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case matcherVersion = "matcher_v"
        case maxBatchSize = "max_batch_size"
        case source, competitions, groups
    }
}

nonisolated struct LumeProxyMetadataCapability: Decodable, Equatable {
    let version: Int
    let maxBatchSize: Int
    let languages: [String]?
    let groups: [String]?

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case maxBatchSize = "max_batch_size"
        case languages, groups
    }
}

/// A value snapshot: no managed Playlist crosses a capability request's await.
/// The hash scopes the account/path/query without storing secrets in cache keys.
nonisolated struct LumeProxySource: Hashable {
    let playlistID: UUID
    let capabilitiesURL: URL
    let identity: String

    init?(playlist: Playlist) {
        guard playlist.knownSourceType == .xtream, let url = XtreamClient.lumeCapabilitiesURL(for: playlist),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        playlistID = playlist.id
        capabilitiesURL = url
        identity = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func snapshot(contentID: String, in context: ModelContext) -> Self? {
        guard let playlist = PlaylistOwner.playlist(forPrefixedID: contentID, in: context) else { return nil }
        return Self(playlist: playlist)
    }

    /// One read for a chunk, not one owner fetch per title (and per receipt).
    static func snapshots(in context: ModelContext) throws -> [UUID: Self] {
        var sources: [UUID: Self] = [:]
        for playlist in try context.fetch(FetchDescriptor<Playlist>()) {
            sources[playlist.id] = Self(playlist: playlist)
        }
        return sources
    }

    static func snapshot(contentID: String, from sources: [UUID: Self]) -> Self? {
        let prefix = String(contentID.prefix(36))
        guard contentID.count > 36, let id = UUID(uuidString: prefix), id.uuidString == prefix else { return nil }
        return sources[id]
    }

    func metadataURL(type: LumeMetadataKind, ids: [Int], language: String) -> URL? {
        guard var components = URLComponents(url: capabilitiesURL, resolvingAgainstBaseURL: false),
              components.percentEncodedPath.hasSuffix("/capabilities") else { return nil }
        components.percentEncodedPath.removeLast("capabilities".count)
        components.percentEncodedPath += "metadata"
        let existing = components.queryItems ?? []
        components.queryItems = existing + [
            URLQueryItem(name: "type", value: type.rawValue),
            URLQueryItem(name: "ids", value: ids.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "language", value: language)
        ]
        return components.url
    }
}

/// Small, process-local negotiation cache shared by sync and future metadata
/// readers. A capability never substitutes for a complete metadata payload.
actor LumeProxyCapabilityStore {
    static let shared = LumeProxyCapabilityStore()

    enum State: Equatable {
        case supported(LumeProxyCapabilities)
        case unsupported
        case unavailable

        var cacheLifetime: TimeInterval {
            switch self {
            case .supported: 3600
            case .unsupported: 6 * 3600
            case .unavailable: 60
            }
        }
    }

    /// Keep availability compatible for existing consumers, but distinguish
    /// server outages from account/payload failures for host-wide backoff.
    struct Negotiation {
        let state: State
        var hostDown = false
    }

    private struct Entry {
        let identity: String
        let negotiation: Negotiation
        let expiresAt: Date
    }

    private struct Flight {
        let id = UUID()
        let task: Task<Negotiation, Never>
    }

    private let session: URLSession
    private var entries: [UUID: Entry] = [:]
    private var inFlight: [String: Flight] = [:]
    private var currentIdentity: [UUID: String] = [:]

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
    }

    /// Reuses a fresh result, coalesces concurrent callers, and bounds a failed
    /// optional probe. Full sync can bypass the cache, but never an in-flight
    /// request. Unavailability is short-lived and never authorises metadata.
    func capabilities(for source: LumeProxySource, refresh: Bool = false, now: Date = Date()) async throws -> State {
        try await negotiation(for: source, refresh: refresh, now: now).state
    }

    func negotiation(for source: LumeProxySource, refresh: Bool = false, now: Date = Date()) async throws -> Negotiation {
        try Task.checkCancellation()
        currentIdentity[source.playlistID] = source.identity
        if let entry = entries[source.playlistID], entry.identity != source.identity {
            entries.removeValue(forKey: source.playlistID)
        }
        if !refresh, let entry = entries[source.playlistID], now < entry.expiresAt {
            return entry.negotiation
        }

        let key = source.playlistID.uuidString + source.identity
        let flight: Flight
        if let existing = inFlight[key] {
            flight = existing
        } else {
            let session = session
            flight = Flight(task: Task { await Self.fetch(source.capabilitiesURL, session: session) })
            inFlight[key] = flight
        }
        let result = await flight.task.value
        if inFlight[key]?.id == flight.id {
            inFlight.removeValue(forKey: key)
        }
        // An old request finishing after an account edit cannot overwrite the
        // new account's cached capabilities. Cancellation never certifies data.
        try Task.checkCancellation()
        if currentIdentity[source.playlistID] == source.identity {
            entries[source.playlistID] = Entry(identity: source.identity, negotiation: result, expiresAt: now.addingTimeInterval(result.state.cacheLifetime))
        }
        return result
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 1
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 5
        config.httpAdditionalHeaders = ["User-Agent": lumeCatalogUserAgent]
        return URLSession(configuration: config)
    }

    private static func fetch(_ url: URL, session: URLSession) async -> Negotiation {
        do {
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
            let (data, response) = try await BoundedResponse.data(for: request, session: session, limit: 65536)
            guard let response = response as? HTTPURLResponse else { return Negotiation(state: .unavailable) }
            if response.statusCode == 404 {
                Logger.network.info("Proxy capabilities: unsupported")
                return Negotiation(state: .unsupported)
            }
            if response.statusCode >= 500 { return Negotiation(state: .unavailable, hostDown: true) }
            guard response.statusCode == 200,
                  let capabilities = try? JSONDecoder().decode(LumeProxyCapabilities.self, from: data) else { return Negotiation(state: .unavailable) }
            guard capabilities.version == 1 else { return Negotiation(state: .unsupported) }
            let batchSize = capabilities.metadataBatchSize ?? 0
            Logger.network.info("Proxy capabilities: v1; metadata batch limit=\(batchSize, privacy: .public)")
            return Negotiation(state: .supported(capabilities))
        } catch is BoundedResponse.TooLarge {
            // A host that answers, too much: not down.
            return Negotiation(state: .unavailable)
        } catch {
            // Do not log URLs/errors: optional API errors can contain credentials.
            return Negotiation(state: .unavailable, hostDown: true)
        }
    }
}
