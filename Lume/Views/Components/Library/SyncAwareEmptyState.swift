//
//  SyncAwareEmptyState.swift
//  Lume
//
//  What an empty library surface shows while the playlist behind it is still
//  syncing, or after that sync failed, in place of its own "nothing here"
//  copy. Syncs run behind the library, so a first import meets empty tabs.
//

import SwiftUI

struct SyncAwareEmptyState<Idle: View>: View {
    @Environment(PlaylistSyncCenter.self) private var center: PlaylistSyncCenter?

    /// The playlist the surface is showing.
    let playlistID: UUID?
    /// The surface's own empty state, shown when no sync explains the gap.
    @ViewBuilder var idle: Idle

    var body: some View {
        if let center, let running = center.running, running.playlistID == playlistID, let progress = center.progress {
            LibrarySyncingPlaceholder(progress: progress)
        } else if center?.isSyncing(playlistID) == true {
            ContentUnavailableView {
                Label("Syncing Your Library", systemImage: "arrow.triangle.2.circlepath")
            } description: {
                Text("Waiting…")
            }
        } else if let failure = center?.recentFailure(for: playlistID) {
            ContentUnavailableView {
                Label("Sync failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(verbatim: failure.failure ?? "")
            } actions: {
                Button("Try Again") { center?.retryRecent() }
            }
        } else {
            idle
        }
    }
}

/// Its own view so the ring and the counts re-render alone, not the tab
/// around them, on every batch the import reports.
private struct LibrarySyncingPlaceholder: View {
    let progress: SyncProgress

    #if os(tvOS)
        private let ringSize: CGFloat = 132
        private let ringWidth: CGFloat = 10
    #else
        private let ringSize: CGFloat = 76
        private let ringWidth: CGFloat = 6
    #endif

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                SyncProgressRing(fraction: progress.overallFraction, lineWidth: ringWidth)
                    .foregroundStyle(Color.lumeAccent)
                progress.overallPercent
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: ringSize, height: ringSize)

            VStack(spacing: 6) {
                Text("Syncing Your Library")
                    .font(.title2.weight(.bold))
                SyncStepLine(progress: progress)
                    .foregroundStyle(.secondary)
            }

            Text("Titles appear here as they arrive.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
