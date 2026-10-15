import Foundation
import OSLog

/// OS model discovery can return nil on first use despite supporting the model.
/// Retry acquisition briefly without blocking a thread, downloading assets, or
/// changing backend. Exhaustion ends this attempt; it is not a permanent cache.
nonisolated enum EmbeddingModelAcquisition {
    static let retryDelays: [Duration] = [.milliseconds(100), .milliseconds(250), .seconds(1)]

    static func acquire<Model>(
        lookup: () -> Model?,
        retryDelays: [Duration] = Self.retryDelays,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> Model? {
        for attempt in 0 ... retryDelays.count {
            try Task.checkCancellation()
            if attempt > 0 {
                Logger.indexing.debug("Embedding model not ready; retry \(attempt) of \(retryDelays.count)")
                try await sleep(retryDelays[attempt - 1])
                try Task.checkCancellation()
            }
            let model = lookup()
            try Task.checkCancellation()
            if let model {
                if attempt > 0 { Logger.indexing.info("Embedding model available after \(attempt) retry(s)") }
                return model
            }
        }
        return nil
    }
}
