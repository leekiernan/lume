//
//  HuePairingModel.swift
//  Lume
//
//  Pairing one Hue Bridge: identify it at an address, then poll `POST /api`
//  while the user presses its link button. Nothing here is logged: host,
//  bridge id and keys stay out of every log line. The tvOS pairing step
//  (`TVHuePairingStep`) drives it.
//

import Foundation
import Observation

/// A bridge to pair with: one found on the network, or a typed address
/// (`bridgeID` nil until the bridge identifies itself).
nonisolated struct HuePairingTarget: Hashable {
    var host: String
    var bridgeID: String?
}

@MainActor
@Observable
final class HuePairingModel {
    /// A bridge that answered at an address, ready to pair.
    struct Bridge {
        let client: HueBridgeClient
        let config: HueBridgeConfig
        let host: String
    }

    enum Phase {
        case idle
        case identifying
        case identified(Bridge)
        case waitingForLinkButton(Bridge)
    }

    /// The link button stays armed for 30 s; polling stops there.
    static let pollWindow: Duration = .seconds(30)
    static let pollInterval: Duration = .seconds(2)

    var address = ""
    private(set) var phase: Phase = .idle
    private(set) var errorMessage: String?

    @ObservationIgnored private let makeClient: (HuePairingTarget) -> HueBridgeClient?
    @ObservationIgnored private let store: HueCredentialStore
    @ObservationIgnored private let pollWindow: Duration
    @ObservationIgnored private let pollInterval: Duration

    init(
        makeClient: @escaping (HuePairingTarget) -> HueBridgeClient? = {
            HueBridgeClient.pairing(host: $0.host, bridgeID: $0.bridgeID)
        },
        store: HueCredentialStore = HueCredentialStore(),
        pollWindow: Duration = HuePairingModel.pollWindow,
        pollInterval: Duration = HuePairingModel.pollInterval
    ) {
        self.makeClient = makeClient
        self.store = store
        self.pollWindow = pollWindow
        self.pollInterval = pollInterval
    }

    var bridgeName: String? {
        switch phase {
        case let .identified(bridge), let .waitingForLinkButton(bridge): bridge.config.name
        case .idle, .identifying: nil
        }
    }

    var isIdentifying: Bool {
        if case .identifying = phase { true } else { false }
    }

    var isWaitingForLinkButton: Bool {
        if case .waitingForLinkButton = phase { true } else { false }
    }

    var isBusy: Bool {
        isIdentifying || isWaitingForLinkButton
    }

    func addressDidChange() {
        errorMessage = nil
    }

    func identify(_ target: HuePairingTarget) async -> Bool {
        guard let client = makeClient(target) else {
            errorMessage = HuePairingStrings.invalidAddress
            return false
        }
        phase = .identifying
        errorMessage = nil
        do {
            let config = try await client.identify()
            phase = .identified(Bridge(client: client, config: config, host: target.host))
            return true
        } catch {
            phase = .idle
            errorMessage = HuePairingStrings.message(for: error)
            return false
        }
    }

    /// Polls until the bridge hands out a key, an error other than "link
    /// button not pressed" comes back, or the poll window runs out. True once
    /// the bridge is stored as this device's only bridge.
    func pair() async -> Bool {
        guard case let .identified(bridge) = phase else { return false }
        phase = .waitingForLinkButton(bridge)
        errorMessage = nil
        defer { if isWaitingForLinkButton { phase = .identified(bridge) } }

        let deadline = ContinuousClock.now + pollWindow
        while true {
            do {
                let credentials = try await bridge.client.pair()
                let secrets = HueBridgeSecrets(credentials: credentials, certificatePin: bridge.client.firstUsePin)
                guard store.savePairing(secrets, for: HueBridgeAddress(id: bridge.config.normalizedID, host: bridge.host)) else {
                    errorMessage = HuePairingStrings.saveFailed
                    return false
                }
                return true
            } catch .linkButtonNotPressed {
                guard ContinuousClock.now + pollInterval < deadline else {
                    errorMessage = HuePairingStrings.linkButtonTimedOut
                    return false
                }
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    return false
                }
            } catch .cancelled {
                return false
            } catch {
                errorMessage = HuePairingStrings.message(for: error)
                return false
            }
        }
    }
}

/// Messages for pairing and the Hue pane. Never interpolates a host, id or key.
nonisolated enum HuePairingStrings {
    static var invalidAddress: String {
        String(localized: "settings.hue.error.invalidAddress", defaultValue: "Enter the bridge's IP address, like 192.168.1.20.")
    }

    static var linkButtonTimedOut: String {
        String(
            localized: "settings.hue.error.linkButton",
            defaultValue: "The link button wasn't pressed in time. Press it, then try again."
        )
    }

    static var saveFailed: String {
        String(localized: "settings.hue.error.saveFailed", defaultValue: "Lume couldn't store the bridge's key on this Apple TV.")
    }

    static func message(for error: HueBridgeError) -> String {
        switch error {
        case .linkButtonNotPressed:
            linkButtonTimedOut
        case .untrustedCertificate, .wrongBridge:
            String(
                localized: "settings.hue.error.untrusted",
                defaultValue: "This address didn't answer as a genuine Hue Bridge."
            )
        case .unauthorized:
            String(
                localized: "settings.hue.error.unauthorized",
                defaultValue: "The bridge no longer knows this Apple TV. Forget the bridge and pair it again."
            )
        case .rateLimited:
            String(localized: "settings.hue.error.rateLimited", defaultValue: "The bridge is busy. Wait a moment, then try again.")
        case .transport, .server, .notFound, .invalidResponse:
            String(
                localized: "settings.hue.error.unreachable",
                defaultValue: "Couldn't reach a Hue Bridge at this address. Check that it's on the same network."
            )
        case .invalidRequest:
            invalidAddress
        case .areaInUse, .pairingFailed, .rejected, .cancelled:
            String(localized: "settings.hue.error.generic", defaultValue: "The bridge turned the request down. Try again.")
        }
    }
}
