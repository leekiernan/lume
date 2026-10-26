//
//  WatchedTrackerIntegration.swift
//  Lume
//
//  What the settings screens for Simkl and MDBList read and drive. Both run
//  the same device-flow connect, watched-history import and pending-change
//  retry, so one screen per platform (`WatchedTrackerIntegrationView`,
//  `TVWatchedTrackerIntegrationView`) serves both; Trakt, which also imports
//  in-progress titles, keeps its own.
//

import SwiftData
import SwiftUI

@MainActor
protocol WatchedTrackerIntegration: AnyObject, Observable {
    var isConnected: Bool { get }
    var isConnecting: Bool { get }
    var username: String? { get }
    var connectionError: String? { get }
    /// The code waiting for approval, and where to approve it.
    var pendingActivation: (code: String, url: URL?)? { get }
    var isImporting: Bool { get }
    var lastImport: TrackerWatchedImportSummary? { get }
    var pendingMutationCount: Int { get }
    var isSyncingMutations: Bool { get }
    var mutationSyncError: String? { get }

    func connect(into context: ModelContext?)
    func cancelConnect()
    func disconnect() async
    func importWatched(into context: ModelContext) async
    func retryPendingMutations()
}

extension SimklService: WatchedTrackerIntegration {
    var pendingActivation: (code: String, url: URL?)? {
        pendingCode.map { ($0.userCode, SimklClient.activationURL(for: $0)) }
    }
}

extension MDBListService: WatchedTrackerIntegration {
    var pendingActivation: (code: String, url: URL?)? {
        pendingCode.map { ($0.userCode, MDBListSyncClient.activationURL(for: $0)) }
    }
}

/// One tracker's words on its settings screen.
struct WatchedTrackerWording {
    let provider: TrackerIntegrationPresentation
    let premiumFeature: PremiumFeature
    let name: LocalizedStringKey
    let connect: LocalizedStringKey
    let pitch: LocalizedStringKey
    let importWatched: LocalizedStringKey
    let retryPending: LocalizedStringKey
    let explanation: LocalizedStringKey
    let pendingChanges: (Int) -> LocalizedStringKey

    static let simkl = Self(
        provider: .simkl,
        premiumFeature: .simkl,
        name: "Simkl",
        connect: "Connect Simkl Account",
        pitch: "Sync the movies and episodes you watch to Simkl, and surface your Simkl watchlist on Home.",
        importWatched: "Import Watched from Simkl",
        retryPending: "Retry Pending Simkl Changes",
        explanation: "Watched movies and episodes sync to your Simkl history. Import marks titles you've already watched on Simkl as watched here.",
        pendingChanges: { "\($0) Simkl changes waiting to sync." }
    )

    static let mdblist = Self(
        provider: .mdblist,
        premiumFeature: .mdblist,
        name: "MDBList",
        connect: "Connect MDBList Account",
        pitch: "Sync the movies and episodes you watch to MDBList, and surface your MDBList watchlist on Home.",
        importWatched: "Import Watched from MDBList",
        retryPending: "Retry Pending MDBList Changes",
        explanation: "Watched movies and episodes sync to your MDBList history. Import marks titles you've already watched on MDBList as watched here.",
        pendingChanges: { "\($0) MDBList changes waiting to sync." }
    )
}
