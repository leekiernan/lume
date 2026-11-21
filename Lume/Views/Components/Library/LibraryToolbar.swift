import SwiftUI

struct LibraryToolbarModifier: ViewModifier {
    let playlists: [Playlist]
    @Binding var selectedPlaylistID: String
    @Binding var showingSync: Bool
    @Binding var showingSettings: Bool
    let activePlaylist: Playlist?

    func body(content: Content) -> some View {
        content
            .toolbar {
                if playlists.count > 1 {
                    ToolbarItem(placement: .automatic) {
                        PlaylistSwitcher(playlists: playlists, selectedPlaylistID: $selectedPlaylistID)
                    }
                }

                // One ToolbarItem each, deliberately not an HStack in a single
                // item: when the bar runs out of room it moves surplus items
                // into a "..." overflow menu, and an item whose content is a
                // stack of buttons has no menu representation — it was dropped
                // outright, leaving no way to reach Settings at all. Separate
                // items degrade into menu rows instead. The titles also give the
                // menu rows (and VoiceOver) real names rather than the symbols'
                // defaults.
                ToolbarItem(placement: .automatic) {
                    LibrarySyncButton(playlist: activePlaylist, showingSync: $showingSync)
                }

                ToolbarItem(placement: .automatic) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                }
            }
            .sheet(
                isPresented: $showingSettings,
                // Settings is a sheet on this toolbar, invisible to the browse
                // root that fires the rating prompt — so it reports itself, the
                // way the paywall and the players do.
                onDismiss: { AppStoreReviewPrompt.shared.noteBlockingSheetDismissed() },
                content: {
                    SettingsView()
                        .onAppear { AppStoreReviewPrompt.shared.noteBlockingSheetAppeared() }
                }
            )
            .sheet(isPresented: $showingSync) {
                SyncActivityView()
            }
    }
}

/// Starts a sync of the playlist on screen behind the library and opens the
/// activity sheet; while one is running, or after one failed, it shows that
/// and only opens the sheet. Its own view so the center's state re-renders
/// this button alone.
private struct LibrarySyncButton: View {
    let playlist: Playlist?
    @Binding var showingSync: Bool
    @Environment(PlaylistSyncCenter.self) private var center: PlaylistSyncCenter?

    var body: some View {
        Button {
            startIfIdle()
            showingSync = true
        } label: {
            if let center, center.running != nil, let progress = center.progress {
                // A plain view rather than a `Label`: the bar draws a `Label`
                // whose icon isn't an image as its title text.
                SyncToolbarRing(progress: progress)
            } else if center?.recentFailure() != nil {
                Label("Sync", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            } else {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }

    /// A failed sync is left for the sheet to show, with its own Try Again.
    private func startIfIdle() {
        guard let center, !center.isBusy, center.recentFailure() == nil, let playlist else { return }
        center.sync(playlist)
    }
}

/// The Sync button while a sync runs: its progress as a ring. Its own view so
/// the per-batch progress writes re-render it alone.
private struct SyncToolbarRing: View {
    let progress: SyncProgress

    var body: some View {
        SyncProgressRing(fraction: progress.overallFraction, lineWidth: 2.5)
            .foregroundStyle(Color.lumeAccent)
            .frame(width: 22, height: 22)
            .accessibilityElement()
            .accessibilityLabel(Text("Sync"))
            .accessibilityValue(progress.overallPercent)
    }
}

struct LibraryToolbarConfiguration {
    let playlists: [Playlist]
    @Binding var selectedPlaylistID: String
    @Binding var showingSync: Bool
    @Binding var showingSettings: Bool
    let activePlaylist: Playlist?
}

extension View {
    func libraryToolbar(config: LibraryToolbarConfiguration) -> some View {
        #if os(tvOS)
            // tvOS surfaces sync/settings through its own library controls.
            return self
        #else
            return modifier(LibraryToolbarModifier(
                playlists: config.playlists,
                selectedPlaylistID: config.$selectedPlaylistID,
                showingSync: config.$showingSync,
                showingSettings: config.$showingSettings,
                activePlaylist: config.activePlaylist
            ))
        #endif
    }
}
