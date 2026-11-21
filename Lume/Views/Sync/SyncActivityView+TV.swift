//
//  SyncActivityView+TV.swift
//  Lume
//
//  The tvOS sync activity screen: the mark, the status and the actions on the
//  left, the steps on the right, on the flat dark fill the settings surfaces
//  share. A plain sheet renders as a clipped centred card there.
//

#if os(tvOS)

    import SwiftUI

    extension SyncActivityView {
        var content: some View {
            HStack(alignment: .center, spacing: 96) {
                VStack(spacing: 44) {
                    tvHeader
                    tvActions
                }
                .frame(width: TVSettingsMetrics.sideColumnWidth)

                VStack(alignment: .leading, spacing: 36) {
                    VStack(alignment: .leading, spacing: 6) {
                        if phase == .idle, let offer {
                            SyncPlanSummary(plan: PlaylistSyncPlan(sourceType: offer.sourceType), large: true)
                        }
                        if let progress {
                            ForEach(progress.steps) { step in
                                TVStepRow(
                                    step: step,
                                    state: progress.state(for: step),
                                    detail: progress.detail(for: step),
                                    fraction: progress.currentStep == step ? progress.stepFraction : 0
                                )
                            }
                        }
                        if let guideStatus { TVSyncGuideRow(status: guideStatus) }
                    }

                    if !upNext.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            TVSettingsSectionLabel("Up Next")
                            ForEach(upNext) { job in
                                Text(verbatim: job.name)
                                    .font(.system(size: 26))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, TVSettingsMetrics.rowHPadding)
                            }
                        }
                    }
                }
                .frame(maxWidth: TVSettingsMetrics.contentMaxWidth, alignment: .leading)
            }
            .padding(.horizontal, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tvSettingsBackground()
        }

        private var tvHeader: some View {
            VStack(spacing: 28) {
                SyncActivitySymbol(phase: phase, progress: progress, size: 160)
                VStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 40, weight: .bold))
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(.system(size: 26))
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                if let progress, phase == .syncing {
                    SyncActivityProgressBar(progress: progress)
                }
            }
            .animation(.snappy, value: phase)
        }

        private var tvActions: some View {
            VStack(spacing: 18) {
                switch phase {
                case .syncing:
                    // As a tab there is nothing to close: the sync carries on
                    // in the background wherever the viewer goes next.
                    if onClose == nil {
                        Button("Continue in Background") { close() }
                            .buttonStyle(TVSettingsActionButtonStyle(prominent: true))
                    }
                    Button("Stop Sync") { stopSync() }
                        .buttonStyle(TVSettingsActionButtonStyle())
                case let .failed(message):
                    Text(verbatim: message)
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        retry()
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(TVSettingsActionButtonStyle(prominent: true))
                    Button("Close") { close() }
                        .buttonStyle(TVSettingsActionButtonStyle())
                case .idle where offer != nil:
                    Button {
                        syncOffer()
                    } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(TVSettingsActionButtonStyle(prominent: true))
                    Button("Cancel") { close() }
                        .buttonStyle(TVSettingsActionButtonStyle())
                case .finished, .idle:
                    Button("Done") { close() }
                        .buttonStyle(TVSettingsActionButtonStyle(prominent: true))
                }
            }
        }
    }

#endif
