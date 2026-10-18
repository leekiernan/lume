import SwiftUI

/// Every sports surface owns its interest in the shared loop. Stable identity
/// makes duplicate appearances/releases harmless without view-local counters.
private struct SportsLivePolling: ViewModifier {
    @State private var lease = ActivityLease()

    func body(content: Content) -> some View {
        content
            .onAppear { SportsSyncService.shared.beginLivePolling(owner: lease) }
            .onDisappear { SportsSyncService.shared.endLivePolling(owner: lease) }
    }
}

extension View {
    func sportsLivePolling() -> some View {
        modifier(SportsLivePolling())
    }
}
