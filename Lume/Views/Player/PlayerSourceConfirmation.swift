import SwiftUI

extension View {
    /// Hosted above the engines: an auto-hiding controls overlay must not own
    /// the warning, or it could disappear while the viewer is deciding.
    func sourceSwitchConfirmation(
        request: Binding<PlayerSourceSwitch.Request?>,
        confirm: @escaping (PlayerSourceSwitch.Request) -> Void
    ) -> some View {
        let isPresented = Binding(
            get: { request.wrappedValue != nil },
            set: { if !$0 { request.wrappedValue = nil } }
        )
        return alert("Different source duration", isPresented: isPresented, presenting: request.wrappedValue) { pending in
            Button("Restart") { confirm(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("These copies have different durations. Restart the selected copy from the beginning?")
        }
    }
}
