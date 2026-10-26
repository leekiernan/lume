//
//  TVWatchedTrackerIntegrationView.swift
//  Lume
//
//  The tvOS Integrations pane content for Simkl and MDBList, shown inside
//  SettingsView's detail column. Drives the OAuth device flow with a
//  scannable QR code (Apple TV can't open a browser), and surfaces the
//  connected account.
//

#if os(tvOS)

    import SwiftData
    import SwiftUI

    struct TVWatchedTrackerIntegrationView<Service: WatchedTrackerIntegration>: View {
        let service: Service
        let wording: WatchedTrackerWording
        /// Both trackers are Premium features.
        @State private var premium = PremiumManager.shared
        @State private var showPaywall = false
        @Environment(\.modelContext) private var modelContext

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                TVSettingsSectionLabel(wording.name)

                if service.isConnected {
                    connected
                } else if let activation = service.pendingActivation {
                    TrackerDeviceCodePanel(provider: wording.provider, code: activation.code, activationURL: activation.url) {
                        service.cancelConnect()
                    }
                } else {
                    connect
                }
            }
            .paywall(isPresented: $showPaywall, highlight: wording.premiumFeature)
            .onDisappear {
                // Stop polling if the user leaves the pane mid-connect.
                if !service.isConnected {
                    service.cancelConnect()
                }
            }
        }

        private var connect: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text(wording.pitch)
                    .font(.system(size: TVSettingsMetrics.statusFontSize))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Button {
                    if premium.isPremium {
                        service.connect(into: modelContext)
                    } else {
                        showPaywall = true
                    }
                } label: {
                    SettingsActionLabel(title: wording.connect, systemImage: premium.isPremium ? "link" : "crown")
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .disabled(service.isConnecting)

                if let error = service.connectionError {
                    Text(error)
                        .font(.system(size: TVSettingsMetrics.explanatoryFontSize))
                        .foregroundStyle(.red)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }
            }
        }

        private var connected: some View {
            VStack(alignment: .leading, spacing: 16) {
                TrackerConnectedAccount(username: service.username)

                Text(wording.explanation)
                    .font(.system(size: TVSettingsMetrics.explanatoryFontSize))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)

                Button {
                    Task { await service.importWatched(into: modelContext) }
                } label: {
                    SettingsActionLabel(title: wording.importWatched, systemImage: "arrow.down.circle", isBusy: service.isImporting)
                }
                .buttonStyle(TVSettingsRowButtonStyle())
                .disabled(service.isImporting)

                if let summary = service.lastImport {
                    TrackerImportStatus(
                        provider: wording.provider, movies: summary.moviesMarked, episodes: summary.episodesMarked,
                        queuedShows: summary.showsQueued, failed: summary.failed
                    )
                }

                // An import waits for these to upload first, so without them
                // on screen a chosen import looked like it did nothing.
                if service.pendingMutationCount > 0 {
                    Button {
                        service.retryPendingMutations()
                    } label: {
                        SettingsActionLabel(title: wording.retryPending, systemImage: "arrow.clockwise", isBusy: service.isSyncingMutations)
                    }
                    .buttonStyle(TVSettingsRowButtonStyle())
                    .disabled(service.isSyncingMutations)

                    (service.mutationSyncError.map { Text($0) } ?? Text(wording.pendingChanges(service.pendingMutationCount)))
                        .font(.system(size: TVSettingsMetrics.explanatoryFontSize))
                        .foregroundStyle(service.mutationSyncError != nil ? .red : .secondary)
                        .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                }

                Button {
                    Task { await service.disconnect() }
                } label: {
                    SettingsActionLabel(title: "Disconnect", systemImage: "xmark.circle")
                }
                .buttonStyle(TVSettingsRowButtonStyle(isDestructive: true))
            }
        }
    }

#endif
