import Foundation

nonisolated extension XtreamClient {
    /// Shared API construction, including the bulk digest requests. Authentication
    /// omits `action`; endpoint-specific parameters follow the credentials/action.
    static func playerAPIURL(
        for playlist: Playlist, action: String? = nil, parameters: [URLQueryItem] = []
    ) -> URL? {
        var items: [URLQueryItem] = []
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        return playlist.connection?.xtreamEndpoint(path: "player_api.php", parameters: items + parameters)
    }

    /// The guide is a standalone EPG source, not part of catalog fetching.
    static func xmltvURL(for playlist: Playlist) -> URL? {
        playlist.connection?.xtreamEndpoint(path: "xmltv.php")
    }

    /// Optional Lume extensions use the same base path, account and provider
    /// query as Xtream, but are never inferred from an ordinary catalogue row.
    static func lumeCapabilitiesURL(for playlist: Playlist) -> URL? {
        playlist.connection?.xtreamEndpoint(path: "lume/v1/capabilities")
    }
}
