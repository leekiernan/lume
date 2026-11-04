//
//  HuePairingModelTests.swift
//  LumeTests
//
//  Pairing against canned bridge answers: identify, poll while the link
//  button isn't pressed, store on success, give up when the window closes.
//  Each test talks to its own host; credentials go to in-memory storage.
//

import Foundation
@testable import Lume
import os
import Testing

@MainActor
struct HuePairingModelTests {
    /// Answers `/api/0/config` with the fixture config and `POST /api` with
    /// "link button not pressed" until `pressAfter` attempts, then success.
    private final class Bridge: Sendable {
        let host = "hue-pairing-\(UUID().uuidString.prefix(8)).test"
        let attempts = OSAllocatedUnfairLock(initialState: 0)

        init(pressAfter: Int?) throws {
            let config = try fixture("hue-config.json")
            let notPressed = try fixture("hue-pairing-link-button.json")
            let paired = try fixture("hue-pairing-success.json")
            let attempts = attempts
            StubURLProtocol.register(host: host) { request in
                if request.url?.path(percentEncoded: false) == "/api/0/config" {
                    return .init(body: config)
                }
                let attempt = attempts.withLock { count in
                    count += 1
                    return count
                }
                if let pressAfter, attempt > pressAfter {
                    return .init(body: paired)
                }
                return .init(body: notPressed)
            }
        }

        var target: HuePairingTarget {
            HuePairingTarget(host: host, bridgeID: nil)
        }
    }

    private func model(store: HueCredentialStore, window: Duration = .seconds(5)) -> HuePairingModel {
        HuePairingModel(
            makeClient: { HueBridgeClient(host: $0.host, applicationKey: nil, session: StubURLProtocol.makeSession()) },
            store: store,
            pollWindow: window,
            pollInterval: .milliseconds(10)
        )
    }

    @Test func `identify names the bridge and readies pairing`() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let bridge = try Bridge(pressAfter: 0)
            let model = model(store: HueCredentialStore(defaults: defaults, storage: InMemoryCredentialStorage()))

            #expect(await model.identify(bridge.target))
            #expect(model.bridgeName != nil)
            #expect(!model.isBusy)
        }
    }

    @Test func `pairing polls until the link button is pressed, then stores the bridge`() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let bridge = try Bridge(pressAfter: 3)
            let store = HueCredentialStore(defaults: defaults, storage: InMemoryCredentialStorage())
            let model = model(store: store)
            #expect(await model.identify(bridge.target))

            #expect(await model.pair())

            #expect(bridge.attempts.withLock { $0 } == 4)
            #expect(store.pairedBridge?.host == bridge.host)
            #expect(store.loadSecrets()?.credentials.clientKey == "00112233445566778899AABBCCDDEEFF")
            #expect(model.errorMessage == nil)
        }
    }

    @Test func `pairing gives up when the link button window closes`() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let bridge = try Bridge(pressAfter: nil)
            let store = HueCredentialStore(defaults: defaults, storage: InMemoryCredentialStorage())
            let model = model(store: store, window: .milliseconds(100))
            #expect(await model.identify(bridge.target))

            #expect(await !model.pair())

            #expect(model.errorMessage == HuePairingStrings.linkButtonTimedOut)
            #expect(store.pairedBridge == nil)
            #expect(!model.isWaitingForLinkButton, "back to identified, so Try Again works")
            #expect(model.bridgeName != nil)
        }
    }

    @Test func `a keychain that refuses the key fails pairing`() async throws {
        try await withIsolatedDefaultsAsync { defaults in
            let bridge = try Bridge(pressAfter: 0)
            let storage = InMemoryCredentialStorage()
            storage.isLocked = true
            let model = model(store: HueCredentialStore(defaults: defaults, storage: storage))
            #expect(await model.identify(bridge.target))

            #expect(await !model.pair())
            #expect(model.errorMessage == HuePairingStrings.saveFailed)
        }
    }

    @Test func `pairing without an identified bridge does nothing`() async {
        let model = HuePairingModel(makeClient: { _ in nil }, store: HueCredentialStore(storage: InMemoryCredentialStorage()))
        #expect(await !model.pair())
        #expect(await !model.identify(HuePairingTarget(host: "x", bridgeID: nil)))
        #expect(model.errorMessage == HuePairingStrings.invalidAddress)
    }
}

/// A fresh UUID-named `UserDefaults` suite for an async body.
private func withIsolatedDefaultsAsync(_ body: (UserDefaults) async throws -> Void) async rethrows {
    let suiteName = UUID().uuidString
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try await body(defaults)
}

private func fixture(_ name: String, filePath: String = #filePath) throws -> String {
    let url = repoRootURL(filePath: filePath).appendingPathComponent("LumeTests/Fixtures/Hue/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}
