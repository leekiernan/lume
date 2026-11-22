//
//  SyncActivityView.swift
//  Lume
//
//  The playlist sync as a sheet: where the running one has got to, how the
//  last one ended, and what is waiting behind it. It reports; the sync
//  belongs to `PlaylistSyncCenter` and keeps running when this is closed.
//
//  iOS, macOS and visionOS use the layout below; tvOS has its own full-screen
//  one in `SyncActivityView+TV`.
//

import SwiftData
import SwiftUI

struct SyncActivityView: View {
    @Environment(PlaylistSyncCenter.self) var center: PlaylistSyncCenter?
    @Environment(\.dismiss) private var dismiss

    /// Shown with a Sync Now button while nothing is running: the tvOS remote
    /// shortcut opens this rather than starting a sync on a long press.
    var offer: Playlist?
    /// Set where this is a tab rather than a presentation (tvOS): there is
    /// nothing to dismiss, so closing means leaving the tab.
    var onClose: (() -> Void)?

    /// The guide refresh that follows a sync bringing in Live TV, which the
    /// screen reports and never waits for (`SyncGuideStatus`).
    @State private var epg = EPGSyncService.shared
    @State private var sawGuideRunning = false
    /// Sync Now was pressed here, so how that sync ends is this screen's news.
    @State private var tookOffer = false

    /// What the sheet is showing. The running sync wins over the last result.
    enum Phase: Equatable {
        case syncing
        case finished
        case failed(String)
        case idle
    }

    var phase: Phase {
        if center?.running != nil { return .syncing }
        guard let recent = center?.recent else { return .idle }
        // Offered a fresh sync, an earlier run that went fine is old news; a
        // failure still shows, with Try Again.
        if offer != nil, !tookOffer, !recent.failed { return .idle }
        return recent.failure.map(Phase.failed) ?? .finished
    }

    var job: PlaylistSyncJob? {
        center?.running ?? center?.recent?.job
    }

    var progress: SyncProgress? {
        phase == .idle ? nil : center?.progress
    }

    var upNext: [PlaylistSyncJob] {
        center?.upNext ?? []
    }

    /// Where the post-sync guide refresh is; only for a sync that refreshed
    /// Live TV.
    var guideStatus: SyncGuideStatus? {
        guard let job, job.plan.refreshesGuide, phase != .idle else { return nil }
        let finishedAt = center?.running == nil ? center?.recent?.finishedAt : nil
        return SyncGuideStatus.status(
            syncFinished: phase == .finished,
            syncFailed: { if case .failed = phase { return true }; return false }(),
            guideRunning: epg.isSyncing,
            sawGuideRunning: sawGuideRunning,
            guideUpdatedSinceSync: finishedAt.map { (EPGSyncSchedule.lastSyncDate ?? .distantPast) > $0 } ?? false
        )
    }

    var body: some View {
        content
            // Its own toast host, above the root and Settings ones it covers:
            // without it, the result of a sync finishing under this screen
            // was drawn behind it and expired unseen.
            .inAppToasts(priority: 2)
            .onChange(of: epg.isSyncing) { _, running in
                if running, center?.recent != nil, center?.running == nil { sawGuideRunning = true }
            }
            .onChange(of: center?.running?.id) { sawGuideRunning = false }
            .onDisappear { center?.acknowledgeRecent() }
    }

    func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    func stopSync() {
        center?.stop()
        close()
    }

    func retry() {
        center?.retryRecent()
    }

    func syncOffer() {
        guard let offer else { return }
        tookOffer = true
        center?.sync(offer)
    }

    var title: LocalizedStringKey {
        switch phase {
        case .syncing: "Syncing your playlist"
        case .finished: "Sync complete"
        case .failed: "Sync failed"
        case .idle: offer == nil ? "Up to date" : "Ready to sync"
        }
    }

    var subtitle: String? {
        job?.name ?? offer?.name
    }
}

// MARK: - Header symbol

/// The brand mark filling with the overall progress while a sync runs, the
/// outcome's symbol otherwise. Its own view so the per-batch progress writes
/// re-render it alone.
struct SyncActivitySymbol: View {
    let phase: SyncActivityView.Phase
    let progress: SyncProgress?
    let size: CGFloat

    var body: some View {
        if phase == .syncing {
            let fraction = progress?.overallFraction ?? 0
            LumeMark(motion: fraction > 0 ? .progress(fraction) : .trace)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.82))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .transition(.scale.combined(with: .opacity))
        }
    }

    private var symbol: String {
        switch phase {
        case .syncing, .idle: "arrow.triangle.2.circlepath"
        case .finished: "checkmark.seal.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        if case .failed = phase { return .red }
        return .lumeAccent
    }
}

/// The overall progress bar under the header. Its own view for the same reason.
struct SyncActivityProgressBar: View {
    let progress: SyncProgress

    var body: some View {
        ProgressView(value: progress.overallFraction)
            .progressViewStyle(.linear)
            .tint(.lumeAccent)
    }
}

/// The running step and its live count, in one line, for the empty-tab
/// placeholder.
struct SyncStepLine: View {
    let progress: SyncProgress

    var body: some View {
        if let step = progress.currentStep {
            let detail = progress.stepDetail
            if detail.isEmpty {
                Text(step.title)
            } else {
                Text(verbatim: "\(String(localized: step.title)) · \(detail)")
                    .monospacedDigit()
            }
        } else {
            Text("Syncing")
        }
    }
}

// MARK: - iOS / macOS / visionOS

#if !os(tvOS)

    extension SyncActivityView {
        var content: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    header
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if phase == .idle, let offer {
                                SyncPlanSummary(plan: PlaylistSyncPlan(sourceType: offer.sourceType))
                            }
                            if let progress {
                                ForEach(progress.steps) { step in
                                    StepRowView(
                                        step: step,
                                        state: progress.state(for: step),
                                        detail: progress.detail(for: step),
                                        fraction: progress.currentStep == step ? progress.stepFraction : 0
                                    )
                                }
                            }
                            if let guideStatus { SyncGuideRow(status: guideStatus) }
                            if !upNext.isEmpty { upNextList }
                        }
                        .padding()
                    }
                    Divider()
                    footer.padding()
                }
                .navigationTitle("Sync")
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { close() }
                        }
                    }
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #endif
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 480)
            #endif
        }

        private var header: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SyncActivitySymbol(phase: phase, progress: progress, size: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        if let subtitle {
                            Text(verbatim: subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .animation(.snappy, value: phase)
                if let progress, phase == .syncing || phase == .finished {
                    SyncActivityProgressBar(progress: progress)
                }
            }
            .padding()
        }

        private var upNextList: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("Up Next")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                ForEach(upNext) { job in
                    Label {
                        Text(verbatim: job.name)
                    } icon: {
                        Image(systemName: "clock")
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }

        @ViewBuilder
        private var footer: some View {
            switch phase {
            case .syncing:
                VStack(spacing: 10) {
                    Text("You can keep using Lume while your playlist syncs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Stop Sync", role: .destructive) { stopSync() }
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity)
            case let .failed(message):
                VStack(spacing: 12) {
                    Text(verbatim: message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        retry()
                    } label: {
                        Label("Try Again", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            case .idle where offer != nil:
                Button {
                    syncOffer()
                } label: {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            case .finished, .idle:
                Button {
                    close()
                } label: {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

#endif
