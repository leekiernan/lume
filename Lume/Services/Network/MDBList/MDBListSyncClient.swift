//
//  MDBListSyncClient.swift
//  Lume
//
//  Stateless networking client for the account side of the MDBList API: the
//  OAuth 2.0 *device* flow (RFC 8628 — the only flow that works on tvOS, and
//  uniform across every platform), token refresh/revoke, the connected user,
//  watched-history sync and import. Scrobbles and paused playback live in
//  MDBListScrobble.swift, the watchlist in MDBListWatchlist.swift. The
//  read-only ratings lookup keyed by the app's own API key stays in
//  `MDBListClient`; this client acts on behalf of a signed-in user.
//
//  MDBList's OAuth endpoints take form-encoded bodies (not JSON) and only
//  answer on their trailing-slash paths. A "Device Code App" registration has
//  no client secret, so only the client id is ever sent.
//
//  The client id lives in the git-ignored `.env` file (MDBLIST_CLIENT_ID) and
//  is injected into Info.plist at build time by Scripts/inject-env.sh.
//

import Foundation

// MARK: - Errors

enum MDBListSyncError: Error, Equatable {
    case notConfigured
    case invalidResponse
    case server(Int)
    case decoding
    case notAuthenticated

    // Device-flow polling outcomes (RFC 8628).
    case authorizationPending
    case slowDown
    case codeExpired
    case accessDenied
    case invalidClient
}

// MARK: - Client

/// Read/write MDBList account client. Stateless: the caller supplies the access
/// token for authenticated endpoints, so token lifecycle lives in
/// `TrackerAccountSession`.
nonisolated struct MDBListSyncClient {
    static let shared = MDBListSyncClient()

    /// `read` alone can't write watched history, and the default scope is
    /// `read`, so both are asked for explicitly.
    private static let scope = "read write"

    /// Largest page the sync and watchlist endpoints document.
    static let pageSize = 1000

    /// Stops a paging loop that the server never ends — no real watchlist or
    /// watched history comes close to 50 000 entries.
    private static let maxPages = 50

    private let session: URLSession
    private let clientID: String?
    private let baseURL: String

    init(
        session: URLSession = .shared,
        clientID: String? = MDBListSyncClient.value(for: "MDBListClientID"),
        baseURL: String = "https://api.mdblist.com"
    ) {
        self.session = session
        self.clientID = clientID
        self.baseURL = baseURL
    }

    /// Whether this build carries a client id. When false the whole integration
    /// is hidden rather than surfacing errors.
    var isConfigured: Bool {
        guard let clientID, !clientID.isEmpty, !clientID.hasPrefix("$(") else { return false }
        return true
    }

    private static func value(for key: String) -> String? {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var appVersion: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
    }

    private static var userAgent: String {
        "Lume/\(appVersion)"
    }

    /// The URL the user opens to approve the device code — the pre-filled
    /// variant when the server returned one, else the plain code page.
    static func activationURL(for code: MDBListDeviceCode) -> URL? {
        if let complete = code.verificationURLComplete, let url = URL(string: complete) {
            return url
        }
        return URL(string: code.verificationURL)
    }

    // MARK: - OAuth: device flow

    /// Requests a device + user code to begin authorization.
    func requestDeviceCode() async throws -> MDBListDeviceCode {
        guard let clientID, isConfigured else { throw MDBListSyncError.notConfigured }
        do {
            return try await postOAuth("/oauth/device-authorization/", form: ["client_id": clientID, "scope": Self.scope])
        } catch MDBListSyncError.server(400) {
            // Only the client id and scope are sent, and MDBList answers an
            // unknown client id with a 400 `invalid_request` rather than
            // `invalid_client`.
            throw MDBListSyncError.invalidClient
        }
    }

    /// Polls once for the token. Maps the RFC 8628 polling outcomes to typed
    /// errors so the session can drive the loop.
    func pollForToken(deviceCode: String) async throws -> MDBListTokenResponse {
        guard let clientID, isConfigured else { throw MDBListSyncError.notConfigured }
        return try await postOAuth("/oauth/token/", form: [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": deviceCode,
            "client_id": clientID
        ])
    }

    /// Exchanges a refresh token for a fresh token set.
    func refreshToken(_ refreshToken: String) async throws -> MDBListTokenResponse {
        guard let clientID, isConfigured else { throw MDBListSyncError.notConfigured }
        return try await postOAuth("/oauth/token/", form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])
    }

    /// Revokes the token server-side. Best-effort: the caller clears the local
    /// token regardless.
    func revokeToken(_ accessToken: String) async throws {
        guard let clientID, isConfigured else { throw MDBListSyncError.notConfigured }
        var request = try makeRequest(path: "/oauth/revoke_token/", method: "POST", accessToken: nil)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await send(request, body: Self.formBody(["token": accessToken, "client_id": clientID]))
        try Self.requireSuccess(response)
    }

    // MARK: - User

    /// The connected user: the name for "Connected as …" and the account id
    /// that scopes queued changes.
    func currentUser(accessToken: String) async throws -> MDBListUser {
        try await get("/user", accessToken: accessToken)
    }

    // MARK: - Watched history (sync)

    /// Marks movies/episodes watched, stamped with the current time.
    func addToHistory(_ items: MDBListSyncItems, accessToken: String) async throws {
        try await post("/sync/watched", body: items, accessToken: accessToken)
    }

    /// Marks movies/episodes unwatched.
    func removeFromHistory(_ items: MDBListSyncItems, accessToken: String) async throws {
        try await post("/sync/watched/remove", body: items, accessToken: accessToken)
    }

    // MARK: - Watched history (import)

    /// The user's whole watched history, every page merged. Only the `movies`
    /// and per-episode `episodes` arrays are read: an episode row carries its
    /// show and season/episode numbers, which is all the import matches on.
    func watchedHistory(accessToken: String) async throws -> MDBListWatchedHistory {
        var history = MDBListWatchedHistory(movies: [], episodes: [])
        try await forEachPage("/sync/watched", accessToken: accessToken) { (page: MDBListWatchedHistory) in
            history.movies += page.movies
            history.episodes += page.episodes
        }
        return history
    }

    // MARK: - Networking

    /// Walks a paginated GET. The live API pages the sync endpoints with a
    /// `next_cursor` while the docs describe `offset` + `has_more`; whichever
    /// the response carries is followed.
    func forEachPage<Page: Decodable & MDBListPaged>(
        _ path: String,
        query: [URLQueryItem] = [],
        accessToken: String,
        handle: (Page) -> Void
    ) async throws {
        var offset = 0
        var cursor: String?
        for _ in 0 ..< Self.maxPages {
            var pageQuery = query + [URLQueryItem(name: "limit", value: String(Self.pageSize))]
            if let cursor {
                pageQuery.append(URLQueryItem(name: "cursor", value: cursor))
            } else {
                pageQuery.append(URLQueryItem(name: "offset", value: String(offset)))
            }
            let page: Page = try await get(path, query: pageQuery, accessToken: accessToken)
            handle(page)

            if let next = page.pagination?.nextCursor, !next.isEmpty {
                cursor = next
            } else if cursor == nil, page.pagination?.hasMore == true, page.itemCount > 0 {
                // The limit may apply per type (movies and shows each), so the
                // offset steps by the page size rather than the rows returned.
                offset += Self.pageSize
            } else {
                return
            }
        }
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], accessToken: String) async throws -> T {
        let request = try makeRequest(path: path, method: "GET", query: query, accessToken: accessToken)
        let (data, response) = try await send(request)
        try Self.requireSuccess(response)
        return try Self.decode(data)
    }

    /// POSTs a JSON payload whose reply isn't acted on, so only the status is
    /// checked.
    func post(_ path: String, body: some Encodable, accessToken: String) async throws {
        let request = try makeRequest(path: path, method: "POST", accessToken: accessToken)
        let (_, response) = try await send(request, body: JSONEncoder().encode(body))
        try Self.requireSuccess(response)
    }

    /// POSTs a JSON payload and decodes the reply.
    func post<T: Decodable>(_ path: String, body: some Encodable, accessToken: String) async throws -> T {
        let request = try makeRequest(path: path, method: "POST", accessToken: accessToken)
        let (data, response) = try await send(request, body: JSONEncoder().encode(body))
        try Self.requireSuccess(response)
        return try Self.decode(data)
    }

    /// POSTs a JSON payload whose status is the answer: the reply is decoded
    /// for the log when it can be, and nil when it can't.
    func postReporting<T: Decodable>(_ path: String, body: some Encodable, accessToken: String) async throws -> T? {
        let request = try makeRequest(path: path, method: "POST", accessToken: accessToken)
        let (data, response) = try await send(request, body: JSONEncoder().encode(body))
        try Self.requireSuccess(response)
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func requireSuccess(_ response: HTTPURLResponse) throws {
        guard (200 ... 299).contains(response.statusCode) else {
            if response.statusCode == 401 {
                throw MDBListSyncError.notAuthenticated
            }
            throw MDBListSyncError.server(response.statusCode)
        }
    }

    private static func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MDBListSyncError.decoding
        }
    }

    /// POSTs a form to an OAuth endpoint. These report failures through an
    /// RFC 6749 §5.2 error envelope (`{"error": "authorization_pending"}`)
    /// rather than plain status codes, so the body is decoded on failure and
    /// mapped to typed errors.
    private func postOAuth<T: Decodable>(_ path: String, form: [String: String]) async throws -> T {
        var request = try makeRequest(path: path, method: "POST", accessToken: nil)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await send(request, body: Self.formBody(form))
        guard (200 ... 299).contains(response.statusCode) else {
            let envelope = try? JSONDecoder().decode(MDBListOAuthError.self, from: data)
            switch envelope?.error {
            case "authorization_pending": throw MDBListSyncError.authorizationPending
            case "slow_down": throw MDBListSyncError.slowDown
            case "expired_token": throw MDBListSyncError.codeExpired
            case "access_denied": throw MDBListSyncError.accessDenied
            case "invalid_client", "unauthorized_client": throw MDBListSyncError.invalidClient
            default: throw MDBListSyncError.server(response.statusCode)
            }
        }
        return try Self.decode(data)
    }

    /// `application/x-www-form-urlencoded`, keys sorted so the body is stable.
    static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = fields.sorted { $0.key < $1.key }.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private func makeRequest(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        accessToken: String?
    ) throws -> URLRequest {
        guard isConfigured, var components = URLComponents(string: baseURL + path) else {
            throw MDBListSyncError.notConfigured
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else { throw MDBListSyncError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Transport only: performs the request and returns the raw body and
    /// response whatever the status.
    private func send(_ request: URLRequest, body: Data? = nil) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = request
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MDBListSyncError.invalidResponse }
        return (data, http)
    }
}

/// RFC 6749 §5.2 error envelope for the `/oauth/*` endpoints.
private nonisolated struct MDBListOAuthError: Decodable {
    let error: String
}
