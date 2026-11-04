//
//  HueBridgeDiscovery.swift
//  Lume
//
//  Bonjour discovery of Hue Bridges (`_hue._tcp`) on the local network. No
//  cloud lookup: a bridge Bonjour can't see is added by IP. Browses only
//  between `start()` and `stop()` — the Hue settings pane owns that window —
//  so the app never browses at launch or triggers the local-network prompt on
//  its own.
//

import Foundation
import Network

/// A bridge seen on the network. `host` is nil until the service resolves.
nonisolated struct DiscoveredHueBridge: Identifiable, Hashable {
    /// The Bonjour service name, unique per domain and therefore the identity.
    let name: String
    /// TXT `bridgeid`, lowercased to match the certificate's common name.
    let bridgeID: String?
    /// TXT `modelid`.
    let modelID: String?
    let host: String?

    var id: String {
        name
    }

    func resolved(to host: String?) -> DiscoveredHueBridge {
        DiscoveredHueBridge(name: name, bridgeID: bridgeID, modelID: modelID, host: host)
    }

    /// The bare host of a resolved `host:port` endpoint, scope removed.
    static func host(for endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        let literal: String
        switch host {
        case let .ipv4(address):
            literal = "\(address)"
        case let .ipv6(address):
            literal = "\(address)"
        case let .name(name, _):
            literal = name
        @unknown default:
            return nil
        }
        let bare = literal.split(separator: "%").first.map(String.init) ?? ""
        return bare.isEmpty ? nil : bare
    }

    /// The bridge id from a TXT `bridgeid` value: 16 hex digits, lowercased.
    static func bridgeID(fromTXT value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count == 16, value.allSatisfy(\.isHexDigit)
        else { return nil }
        return value.lowercased()
    }
}

#if os(tvOS)
    import Observation
    import os

    /// Browses `_hue._tcp` and resolves each bridge to the bare host
    /// `HueBridgeClient` takes. A no-op under tests and previews.
    @MainActor
    @Observable
    final class HueBridgeDiscovery {
        enum State: Equatable {
            case idle
            case browsing
            /// The browser is up but can't see the network yet — typically while
            /// the local-network prompt is open, or after it was declined. It
            /// keeps running and resumes on its own once access is allowed.
            case waitingForLocalNetwork
            /// Browsing failed for good; `start()` again to retry.
            case unavailable
        }

        private(set) var state: State = .idle
        private(set) var bridges: [DiscoveredHueBridge] = []

        @ObservationIgnored private var browser: NWBrowser?
        @ObservationIgnored private var endpoints: [String: NWEndpoint] = [:]
        @ObservationIgnored private var resolveTasks: [String: Task<Void, Never>] = [:]
        /// Bumped on every start/stop so callbacks from a torn-down browser are dropped.
        @ObservationIgnored private var generation = 0

        /// Starts browsing. A browser that is already up — browsing or waiting
        /// for local-network access — is kept; one that failed is replaced.
        func start() {
            guard !LumeApp.isTestOrPreviewHost, browser == nil else { return }
            resetResults()
            generation += 1
            let token = generation
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_hue._tcp", domain: nil), using: .tcp)
            // Both handlers fire on the main queue the browser is started on.
            browser.stateUpdateHandler = { [weak self] browserState in
                MainActor.assumeIsolated { self?.handle(browserState, generation: token) }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                MainActor.assumeIsolated { self?.handle(results, generation: token) }
            }
            self.browser = browser
            state = .browsing
            browser.start(queue: .main)
        }

        func stop() {
            generation += 1
            browser?.cancel()
            browser = nil
            resetResults()
            state = .idle
        }

        private func resetResults() {
            resolveTasks.values.forEach { $0.cancel() }
            resolveTasks = [:]
            endpoints = [:]
            bridges = []
        }

        private func handle(_ browserState: NWBrowser.State, generation token: Int) {
            guard token == generation else { return }
            switch browserState {
            case .ready:
                state = .browsing
            case let .waiting(error):
                // Not final: the user may still allow local-network access, and
                // the browser moves to `.ready` by itself when they do.
                let reason = LogRedaction.describe(error)
                Logger.network.log("Hue discovery waiting: \(reason, privacy: .public)")
                state = .waitingForLocalNetwork
            case let .failed(error):
                let reason = LogRedaction.describe(error)
                Logger.network.error("Hue discovery failed: \(reason, privacy: .public)")
                browser?.cancel()
                browser = nil
                state = .unavailable
            default:
                break
            }
        }

        private func handle(_ results: Set<NWBrowser.Result>, generation token: Int) {
            guard token == generation else { return }
            var next: [DiscoveredHueBridge] = []
            var seen: Set<String> = []
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint, seen.insert(name).inserted else { continue }
                var txt: NWTXTRecord?
                if case let .bonjour(record) = result.metadata { txt = record }
                let known = bridges.first { $0.name == name }
                let bridge = DiscoveredHueBridge(
                    name: name,
                    bridgeID: DiscoveredHueBridge.bridgeID(fromTXT: txt?["bridgeid"]),
                    modelID: txt?["modelid"],
                    host: endpoints[name] == result.endpoint ? known?.host : nil
                )
                next.append(bridge)
                if endpoints[name] != result.endpoint || (bridge.host == nil && resolveTasks[name] == nil) {
                    endpoints[name] = result.endpoint
                    resolve(name: name, endpoint: result.endpoint, generation: token)
                }
            }
            for gone in Set(endpoints.keys).subtracting(seen) {
                endpoints[gone] = nil
                resolveTasks.removeValue(forKey: gone)?.cancel()
            }
            bridges = next.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        private func resolve(name: String, endpoint: NWEndpoint, generation token: Int) {
            resolveTasks[name]?.cancel()
            resolveTasks[name] = Task { [weak self] in
                let host = await HueBridgeResolver.host(for: endpoint)
                guard !Task.isCancelled, let self, token == generation else { return }
                resolveTasks[name] = nil
                guard endpoints[name] == endpoint, let index = bridges.firstIndex(where: { $0.name == name }) else { return }
                bridges[index] = bridges[index].resolved(to: host)
            }
        }
    }

    /// Turns a Bonjour service endpoint into a host by briefly connecting to
    /// it. IPv4 first: the host is stored and reused across launches, and an
    /// IPv6 link-local address only means something with its interface scope.
    nonisolated enum HueBridgeResolver {
        static func host(for endpoint: NWEndpoint) async -> String? {
            if let host = await connect(to: endpoint, ipv4Only: true).flatMap(DiscoveredHueBridge.host(for:)) {
                return host
            }
            guard !Task.isCancelled else { return nil }
            return await connect(to: endpoint, ipv4Only: false).flatMap(DiscoveredHueBridge.host(for:))
        }

        private static let queue = DispatchQueue(label: "app.lume.hue.resolve")
        private static let timeout: DispatchTimeInterval = .seconds(5)

        /// The connection's resolved remote endpoint, or nil when it didn't connect.
        private static func connect(to endpoint: NWEndpoint, ipv4Only: Bool) async -> NWEndpoint? {
            let parameters = NWParameters.tcp
            if ipv4Only, let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ipOptions.version = .v4
            }
            let connection = NWConnection(to: endpoint, using: parameters)
            let finished = OSAllocatedUnfairLock(initialState: false)

            return await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<NWEndpoint?, Never>) in
                    let finish: @Sendable (NWEndpoint?) -> Void = { remote in
                        let first = finished.withLock { done in
                            defer { done = true }
                            return !done
                        }
                        guard first else { return }
                        connection.cancel()
                        continuation.resume(returning: remote)
                    }
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: finish(connection.currentPath?.remoteEndpoint)
                        case .failed, .waiting, .cancelled: finish(nil)
                        default: break
                        }
                    }
                    connection.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
                }
            } onCancel: {
                connection.cancel()
            }
        }
    }
#endif
