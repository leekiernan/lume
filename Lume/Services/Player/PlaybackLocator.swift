import Foundation

/// A portal command is not a URL. Interpret scalar storage with its source
/// kind once, then hand the player an explicit deferred or direct locator.
nonisolated enum PlaybackLocator {
    struct PortalCommand {
        let type: StalkerLink.LinkType
        let value: String

        init?(type: StalkerLink.LinkType, value: String?) {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self.type = type
            self.value = value
        }
    }

    case direct(URL)
    case portal(PortalCommand)

    init?(stored value: String?, source: PlaylistSourceType, portalType: StalkerLink.LinkType) {
        if source == .stalker {
            guard let command = PortalCommand(type: portalType, value: value) else { return nil }
            self = .portal(command)
        } else {
            // Playback intentionally permits file, RTSP, UDP and other engine
            // schemes. The stricter http(s)-only image policy does not apply.
            guard let value, let url = URL(string: value), url.scheme != nil else { return nil }
            self = .direct(url)
        }
    }

    var playerURL: URL? {
        switch self {
        case let .direct(url): url
        case let .portal(command): StalkerLink.placeholder(type: command.type, cmd: command.value)
        }
    }
}

nonisolated extension Movie {
    func playbackLocator(source: PlaylistSourceType) -> PlaybackLocator? {
        PlaybackLocator(stored: directURL, source: source, portalType: .vod)
    }
}

nonisolated extension Episode {
    func playbackLocator(source: PlaylistSourceType) -> PlaybackLocator? {
        PlaybackLocator(stored: directSource, source: source, portalType: .vod)
    }
}

nonisolated extension LiveStream {
    func playbackLocator(source: PlaylistSourceType) -> PlaybackLocator? {
        PlaybackLocator(stored: directURL, source: source, portalType: .itv)
    }
}
