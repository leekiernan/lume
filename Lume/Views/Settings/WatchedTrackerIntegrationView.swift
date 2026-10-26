//
//  WatchedTrackerIntegrationView.swift
//  Lume
//
//  The iOS/macOS integration screen for Simkl and MDBList (the tvOS surface
//  is `TVWatchedTrackerIntegrationView`, shown in SettingsView's Integrations
//  pane). Drives the OAuth device flow: shows the activation code with a
//  one-tap link to the pre-filled approval page, polls in the background, and
//  surfaces the connected account with import and disconnect actions.
//

#if !os(tvOS)

    import SwiftData
    import SwiftUI

    struct WatchedTrackerIntegrationView<Service: WatchedTrackerIntegration>: View {
        let service: Service
        let wording: WatchedTrackerWording
        /// Both trackers are Premium features.
        @State private var premium = PremiumManager.shared
        @State private var showPaywall = false
        @Environment(\.modelContext) private var modelContext

        var body: some View {
            List {
                if service.isConnected {
                    connectedSection
                } else if let activation = service.pendingActivation {
                    deviceCodeSection(activation)
                } else {
                    connectSection
                }
            }
            .platformNavigationTitle(wording.name)
            .paywall(isPresented: $showPaywall, highlight: wording.premiumFeature)
            .onDisappear {
                // Stop polling if the user backs out mid-connect.
                if !service.isConnected {
                    service.cancelConnect()
                }
            }
        }

        // MARK: - Connect

        private var connectSection: some View {
            Section {
                Button {
                    if premium.isPremium {
                        service.connect(into: modelContext)
                    } else {
                        showPaywall = true
                    }
                } label: {
                    SettingsActionLabel(title: wording.connect, systemImage: premium.isPremium ? "link" : "crown")
                }
                .disabled(service.isConnecting)
            } header: {
                Text(wording.name)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(wording.pitch)
                    if let error = service.connectionError {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
        }

        // MARK: - Device code

        private func deviceCodeSection(_ activation: (code: String, url: URL?)) -> some View {
            Section {
                TrackerDeviceCodePanel(provider: wording.provider, code: activation.code, activationURL: activation.url) {
                    service.cancelConnect()
                }
            }
        }

        // MARK: - Connected

        private var connectedSection: some View {
            Section {
                TrackerConnectedAccount(username: service.username)

                Button {
                    Task { await service.importWatched(into: modelContext) }
                } label: {
                    SettingsActionLabel(title: wording.importWatched, systemImage: "arrow.down.circle", isBusy: service.isImporting)
                }
                .disabled(service.isImporting)

                // An import waits for these to upload first, so without them
                // on screen a tapped import looked like it did nothing.
                if service.pendingMutationCount > 0 {
                    Button {
                        service.retryPendingMutations()
                    } label: {
                        SettingsActionLabel(title: wording.retryPending, systemImage: "arrow.clockwise", isBusy: service.isSyncingMutations)
                    }
                    .disabled(service.isSyncingMutations)
                }

                Button(role: .destructive) {
                    Task { await service.disconnect() }
                } label: {
                    SettingsActionLabel(title: "Disconnect", systemImage: "xmark.circle")
                }
            } header: {
                Text(wording.name)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(wording.explanation)
                    if let summary = service.lastImport {
                        importStatus(summary)
                    }
                    if service.pendingMutationCount > 0 {
                        if let error = service.mutationSyncError {
                            Text(error)
                                .foregroundStyle(.red)
                        } else {
                            Text(wording.pendingChanges(service.pendingMutationCount))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }

        private func importStatus(_ summary: TrackerWatchedImportSummary) -> some View {
            TrackerImportStatus(
                provider: wording.provider, movies: summary.moviesMarked, episodes: summary.episodesMarked,
                queuedShows: summary.showsQueued, failed: summary.failed
            )
        }
    }

#endif
