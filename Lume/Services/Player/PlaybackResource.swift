import Foundation

/// A transient handoff, never written into PlayableMedia or restoration state.
nonisolated struct PlaybackResource: Equatable, Hashable {
    let url: URL
    let headers: [String: String]?

    var needsPreparation: Bool {
        HTTPOrigin(url) != nil && headers?.isEmpty == false
    }
}

/// Resolve authenticated redirects before native engines open the stream.
/// Headers remain on the original origin. At the first foreign origin we stop
/// probing and hand off without them; native code never sees a reusable source
/// header while following that cross-origin redirect.
nonisolated enum PlaybackResourceResolver {
    static let timeout: TimeInterval = 4
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    static func resolve(_ resource: PlaybackResource, session: URLSession = session,
                        timeout: TimeInterval = timeout) async throws -> PlaybackResource
    {
        try Task.checkCancellation()
        guard resource.needsPreparation else { return resource }
        return try await withThrowingTaskGroup(of: PlaybackResource.self) { group in
            group.addTask { try await follow(resource, session: session) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func follow(_ resource: PlaybackResource, session: URLSession) async throws -> PlaybackResource {
        let origin = HTTPOrigin(resource.url)
        var current = resource.url
        var visited = Set<URL>()
        for _ in 0 ..< 8 {
            try Task.checkCancellation()
            guard visited.insert(current).inserted else { throw URLError(.httpTooManyRedirects) }
            var request = URLRequest(url: current, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
            request.allHTTPHeaderFields = resource.headers
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            // Headers only, including when the server ignores Range. No media
            // body is collected and Foundation cannot auto-follow Location.
            let (bytes, response) = try await session.bytes(for: request, delegate: RefuseRedirects())
            bytes.task.cancel()
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard [301, 302, 303, 307, 308].contains(response.statusCode) else {
                return PlaybackResource(url: current, headers: resource.headers)
            }
            guard let location = response.value(forHTTPHeaderField: "Location"),
                  let target = URL(string: location, relativeTo: current)?.absoluteURL,
                  HTTPOrigin(target) != nil,
                  target.user == nil, target.password == nil,
                  !(current.scheme?.lowercased() == "https" && target.scheme?.lowercased() != "https")
            else { throw URLError(.redirectToNonExistentLocation) }
            guard HTTPOrigin(target) == origin else { return PlaybackResource(url: target, headers: nil) }
            current = target
        }
        throw URLError(.httpTooManyRedirects)
    }

    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                        newRequest _: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void)
        {
            completionHandler(nil)
        }
    }
}

/// One preparation belongs to one engine load. Replacement and teardown retire
/// both its task and its authority to deliver late callbacks.
@MainActor
final class PlaybackResourcePreparation {
    private var task: Task<Void, Never>?
    private var generation = RequestToken()
    private let resolve: @Sendable (PlaybackResource) async throws -> PlaybackResource

    var isPreparing: Bool {
        task != nil
    }

    init(resolve: @escaping @Sendable (PlaybackResource) async throws -> PlaybackResource = { try await PlaybackResourceResolver.resolve($0) }) {
        self.resolve = resolve
    }

    func prepare(_ resource: PlaybackResource, onReady: @escaping @MainActor (PlaybackResource) -> Void,
                 onFailure: @escaping @MainActor () -> Void)
    {
        cancel()
        guard resource.needsPreparation else { onReady(resource); return }
        let token = generation
        let resolve = resolve
        task = Task { [weak self] in
            do {
                let result = try await resolve(resource)
                guard let self, !Task.isCancelled, generation == token else { return }
                task = nil
                onReady(result)
            } catch {
                guard let self, !Task.isCancelled, generation == token else { return }
                task = nil
                onFailure()
            }
        }
    }

    func cancel() {
        generation = RequestToken()
        task?.cancel()
        task = nil
    }
}
