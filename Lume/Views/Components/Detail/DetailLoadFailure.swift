import SwiftUI

/// Optional detail lanes share a retry surface without replacing cached content.
struct DetailLoadFailure: View {
    let message: LocalizedStringKey
    let retry: () async -> Void

    init(_ message: LocalizedStringKey, retry: @escaping () async -> Void) {
        self.message = message
        self.retry = retry
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(message).foregroundStyle(.secondary)
            Button("Retry") { Task { await retry() } }
            #if os(tvOS)
                .buttonStyle(FilterChipStyle(isSelected: false, shape: .tab))
            #else
                .buttonStyle(.bordered)
            #endif
        }
    }
}
