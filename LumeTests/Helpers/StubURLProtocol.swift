//
//  StubURLProtocol.swift
//  LumeTests
//
//  Shared canned-response `URLProtocol` for client tests.
//
//  It is never registered globally (`URLProtocol.registerClass`): that would
//  intercept `URLSession.shared` for every other suite and make results depend
//  on test order. Use `makeSession()` and inject the result into the client
//  under test.
//

import Foundation

final nonisolated class StubURLProtocol: URLProtocol {
    struct Response {
        var status: Int
        var body: String
        var headers: [String: String]
        var error: URLError?

        init(status: Int = 200, body: String = "", headers: [String: String] = [:], error: URLError? = nil) {
            self.status = status
            self.body = body
            self.headers = headers
            self.error = error
        }
    }

    /// Routes are keyed by host plus one query item, so suites whose requests
    /// all share a single host (IntroDB is one) can still run in parallel by
    /// giving each test a distinct discriminator value.
    private struct RouteKey: Hashable {
        let host: String
        let queryName: String
        let queryValue: String
        /// When set, the route matches on the URL path instead of a query item.
        var pathSuffix: String?
    }

    /// Routes for requests that carry no query at all (the MDBList list feed is
    /// one), keyed by host plus exact path — still distinct per test.
    private struct PathKey: Hashable {
        let host: String
        let path: String
    }

    /// Answers every request to one host, for clients whose calls differ by
    /// method and path rather than by query (the Hue Bridge's CLIP API).
    typealias Handler = @Sendable (URLRequest) -> Response

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handlers: [String: Handler] = [:]
    private nonisolated(unsafe) static var routes: [RouteKey: Response] = [:]
    private nonisolated(unsafe) static var pathRoutes: [PathKey: Response] = [:]
    private nonisolated(unsafe) static var receivedRequests: [String: [URLRequest]] = [:]

    static func requests(forHost host: String) -> [URLRequest] {
        lock.withLock { receivedRequests[host] ?? [] }
    }

    /// Registers `response` for requests to `host` carrying `query`, which is
    /// how tests sharing a host stay isolated from each other.
    static func register(host: String, query: (name: String, value: String), response: Response) {
        let key = RouteKey(host: host, queryName: query.name, queryValue: query.value)
        lock.withLock { routes[key] = response }
    }

    /// Registers `response` for requests to `host` at exactly `path`.
    static func register(host: String, path: String, response: Response) {
        let key = PathKey(host: host, path: path)
        lock.withLock { pathRoutes[key] = response }
    }

    /// Registers `response` for requests to `host` whose path ends in
    /// `pathSuffix`, for endpoints that carry no query item to discriminate on.
    static func register(host: String, pathSuffix: String, response: Response) {
        let key = RouteKey(host: host, queryName: "", queryValue: "", pathSuffix: pathSuffix)
        lock.withLock { routes[key] = response }
    }

    /// Routes every request to `host` through `handler`, clearing what the
    /// host recorded before. Recorded requests carry their body in `httpBody`.
    static func register(host: String, handler: @escaping Handler) {
        lock.withLock {
            handlers[host] = handler
            receivedRequests[host] = []
        }
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    // `URLProtocol` requires these as `class func` overrides — `static` can't
    // override.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let host = components.host ?? ""
        let items = components.queryItems ?? []

        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            captured.httpBody = Self.read(stream)
        }
        let handler = Self.lock.withLock {
            Self.receivedRequests[host, default: []].append(captured)
            return Self.handlers[host]
        }
        let match = handler.map { $0(captured) } ?? Self.lock.withLock {
            Self.routes.first { key, _ in
                guard key.host == host else { return false }
                if let suffix = key.pathSuffix { return components.path.hasSuffix(suffix) }
                return items.contains { $0.name == key.queryName && $0.value == key.queryValue }
            }?.value ?? Self.pathRoutes[PathKey(host: host, path: components.path)]
        }

        if let error = match?.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let match, let response = HTTPURLResponse(
            url: url, statusCode: match.status, httpVersion: nil, headerFields: match.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(match.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
