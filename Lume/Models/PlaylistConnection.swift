import Foundation

/// A validated, non-persisted source snapshot. Storage stays lightweight and
/// backwards-compatible; operations cannot accidentally interpret a Plex token
/// as an Xtream password or an unknown source as Xtream.
nonisolated enum PlaylistConnection: Hashable {
    struct Credentials: Hashable {
        let username: String
        let password: String
    }

    case xtream(endpoint: URL, credentials: Credentials)
    case m3u(URL)
    case stalker(portal: URL, mac: String, credentials: Credentials)
    case webDAV(endpoint: URL, credentials: Credentials)
    case mediaServer(flavor: MediaServerFlavor, endpoint: URL, credentials: Credentials, session: JellyfinSession?)
    case plex(endpoint: URL, token: String?)

    init?(playlist: Playlist) {
        guard let source = playlist.knownSourceType,
              let endpoint = URL(string: playlist.serverURL) else { return nil }
        let isServer = ["http", "https"].contains(endpoint.scheme?.lowercased() ?? "") && endpoint.host?.isEmpty == false
        guard isServer || (endpoint.isFileURL && source == .m3u) else { return nil }
        let credentials = Credentials(username: playlist.username, password: playlist.password)
        switch source {
        case .xtream: self = .xtream(endpoint: endpoint, credentials: credentials)
        case .m3u: self = .m3u(endpoint)
        case .stalker:
            guard let mac = playlist.macAddress, !mac.isEmpty else { return nil }
            self = .stalker(portal: endpoint, mac: mac, credentials: credentials)
        case .webdav: self = .webDAV(endpoint: endpoint, credentials: credentials)
        case .jellyfin, .emby:
            let session: JellyfinSession? = if let token = playlist.jellyfinAccessToken, !token.isEmpty,
                                               let userID = playlist.jellyfinUserId, !userID.isEmpty
            { JellyfinSession(accessToken: token, userId: userID) } else { nil }
            self = .mediaServer(flavor: source == .emby ? .emby : .jellyfin, endpoint: endpoint, credentials: credentials, session: session)
        case .plex: self = .plex(endpoint: endpoint, token: playlist.plexAccessToken)
        }
    }

    var sourceType: PlaylistSourceType {
        switch self {
        case .xtream: .xtream
        case .m3u: .m3u
        case .stalker: .stalker
        case .webDAV: .webdav
        case let .mediaServer(flavor, _, _, _): flavor.sourceType
        case .plex: .plex
        }
    }

    func playbackHeaders(for resource: URL) -> [String: String]? {
        let endpoint: URL? = switch self {
        case let .webDAV(server, _), let .mediaServer(_, server, _, _), let .plex(server, _): server
        case .xtream, .m3u, .stalker: nil
        }
        guard let endpoint, ArtworkRedirectPolicy.sameOrigin(endpoint, resource) else { return nil }
        return authenticationHeaders
    }

    private var authenticationHeaders: [String: String]? {
        switch self {
        case let .webDAV(_, credentials) where !credentials.username.isEmpty:
            ["Authorization": "Basic " + Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()]
        case let .mediaServer(_, _, _, session): JellyfinClient.playbackHeaders(token: session?.accessToken)
        case let .plex(_, token): PlexClient.playbackHeaders(token: token)
        case .xtream, .m3u, .stalker, .webDAV: nil
        }
    }

    func xtreamStream(path: [String]) -> URL? {
        guard case let .xtream(endpoint, credentials) = self,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        let parts = Array(path.prefix(1)) + [credentials.username, credentials.password] + Array(path.dropFirst())
        let encoded = parts.compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }
        guard encoded.count == parts.count else { return nil }
        components.percentEncodedPath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + ([components.percentEncodedPath].filter { !$0.isEmpty } + encoded).joined(separator: "/")
        return components.url
    }
}

nonisolated extension Playlist {
    var connection: PlaylistConnection? {
        PlaylistConnection(playlist: self)
    }
}
