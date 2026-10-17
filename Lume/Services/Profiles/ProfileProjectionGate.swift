import Foundation

/// The catalogue projects one viewer at a time. A generation check alone cannot
/// fence a synchronous save already underway when that projection is replaced.
/// Hold this only for synchronous local work, never across a suspension/network
/// request. Metadata and catalogue imports do not use this viewer-state gate.
final nonisolated class ProfileProjectionGate: @unchecked Sendable {
    static let shared = ProfileProjectionGate()
    private let lock = NSRecursiveLock()

    func withExclusive<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    func withCurrent<Value>(_ scope: ProfileScope, operation: () throws -> Value) rethrows -> Value? {
        try withExclusive {
            guard scope.isCurrent else { return nil }
            return try operation()
        }
    }
}
