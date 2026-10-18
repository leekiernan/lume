import Foundation
@testable import Lume
import Synchronization

/// Holds the profile projection gate on a thread of its own, so a switch
/// started meanwhile parks inside the engine's projection swap and its
/// in-flight state can be read deterministically. `end()` is idempotent.
final class ProjectionHold: @unchecked Sendable {
    private let release = DispatchSemaphore(value: 0)
    private let ended = Mutex(false)

    init() {
        let held = DispatchSemaphore(value: 0)
        Thread { [release] in
            ProfileProjectionGate.shared.withExclusive {
                held.signal()
                release.wait()
            }
        }.start()
        held.wait()
    }

    func end() {
        guard ended.withLock({ ended in defer { ended = true }; return !ended }) else { return }
        release.signal()
    }
}
