import SwiftData
import SwiftUI

extension EnvironmentValues {
    @Entry var artworkOwnerID: String?
}

extension View {
    func artworkOwner(_ id: String?) -> some View {
        environment(\.artworkOwnerID, id)
    }

    func observeArtworkAccounts() -> some View {
        modifier(ArtworkAccountObserver())
    }
}

/// Observe only playlists, not every catalogue save. Token refresh and source
/// edits replace the small credential table without rewriting any image rows.
private struct ArtworkAccountObserver: ViewModifier {
    @Query private var playlists: [Playlist]

    func body(content: Content) -> some View {
        content.onChange(of: playlists.compactMap(ProviderArtworkAccount.init), initial: true) { _, accounts in
            ProviderArtworkAccounts.shared.replace(accounts)
        }
    }
}
