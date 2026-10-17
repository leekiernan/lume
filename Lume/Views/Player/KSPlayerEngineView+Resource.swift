import KSPlayer

extension KSPlayerEngineView {
    var resourceRequest: PlaybackResource {
        PlaybackResource(url: streamURL, headers: media.httpHeaders)
    }

    /// No native player is mounted until a protected source's input is scoped.
    /// The key also hides the previous input immediately on a stream switch.
    var playbackResource: PlaybackResource? {
        let request = resourceRequest
        if !request.needsPreparation { return request }
        return preparedResource?.request == request ? preparedResource?.resource : nil
    }

    func prepareResource() {
        let request = resourceRequest
        guard request.needsPreparation else { resourcePreparation.cancel(); return }
        resourcePreparation.prepare(request, onReady: { resource in
            preparedResource = (request, resource)
        }, onFailure: { failPlayback() })
    }

    /// Retry from the source, never from an expired CDN token. The mounted URL
    /// remains stable so a SwiftUI update cannot trigger a second rebuild.
    func rebuildAuthenticated(on layer: KSPlayerLayer) {
        let request = PlaybackResource(url: media.url, headers: media.httpHeaders)
        resourcePreparation.prepare(request, onReady: { resource in
            guard coordinator.playerLayer === layer else { return }
            let input = PlaybackCredentials.input(for: .ksPlayer, url: resource.url, headers: resource.headers)
            input.apply(to: layer.options)
            rebuildStream(on: layer, url: input.url)
        }, onFailure: { failPlayback() })
    }
}
