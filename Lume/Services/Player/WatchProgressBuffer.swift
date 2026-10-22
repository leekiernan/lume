import Foundation

/// Crash-recovery buffer for in-flight watch progress.
///
/// Committing watch progress to SwiftData on a timer forces the main context to
/// merge the change and re-run every `@Query` observing `Movie`/`Episode`/
/// `Series` — most visibly the Home screen's continue-watching rows — on the
/// main thread. That merge is what hitched KSPlayer's render loop every few
/// seconds, even when the `save()` itself ran on a background context.
///
/// So during playback the player only stashes progress here, and commits it to
/// SwiftData at boundaries — close, episode switch, leaving the foreground.
/// Whatever is still buffered after a crash or force-quit is recovered on the
/// next launch (`WatchProgressWriter.reconcilePending`). The sampler was once
/// switched off "to reduce CPU overhead", unmeasured, and the buffer then
/// removed as dead code — losing every position since the last boundary on a
/// kill. Measured upstream since: ~0.3 µs per sample on the main actor and
/// ~0.23 ms on the queue, nothing attributed to it in a 65 s tvOS trace.
///
/// The write path stays minimal: a flat primitive `UserDefaults` layout (no
/// JSON, no whole-dictionary read-modify-write) on a serial `.background`
/// queue that yields to the video pipeline, with a dedup so a paused clock
/// rewrites nothing.
///
/// Entries are keyed by profile: the writer only commits for the profile that
/// is active, so a position from another profile waits for that profile.
nonisolated enum WatchProgressBuffer {
    enum Kind: String { case movie, episode }

    struct Entry: Equatable {
        let profile: String
        let kind: Kind
        let id: String
        let progress: TimeInterval
        let duration: TimeInterval
        /// When the position was sampled, for the watch date and for telling
        /// a tracker's newer pause from ours.
        let recordedAt: Date

        var contentRef: PlayableMedia.ContentRef {
            switch kind {
            case .movie: .movie(id)
            case .episode: .episode(id)
            }
        }
    }

    /// One key per pending item; value `[progress, duration, recordedAt]`.
    private static let prefix = "watchProgress.v2."

    /// Serializes the writes at the lowest priority, off the caller's thread:
    /// the player samples on the main actor, where KSPlayer presents frames.
    private static let queue = DispatchQueue(label: "com.lume.watchprogressbuffer", qos: .background)

    /// Last progress written per key, so a paused stream doesn't rewrite
    /// `UserDefaults` every tick. Touched only on `queue`.
    private nonisolated(unsafe) static var lastProgress: [String: TimeInterval] = [:]

    /// Stash the latest progress for `ref`, overwriting any earlier value.
    /// Live streams carry no resumable progress and are ignored.
    ///
    /// `waitUntilWritten` blocks until the value has reached `UserDefaults`.
    /// Only for the moment the app leaves the foreground: tvOS can suspend the
    /// process before a `.background` queue gets a turn, and a kill from the
    /// app switcher would then take the position with it. Never during playback.
    static func record(
        ref: PlayableMedia.ContentRef,
        progress: TimeInterval,
        duration: TimeInterval,
        profileID: UUID?,
        recordedAt: Date = .now,
        waitUntilWritten: Bool = false,
        defaults: UserDefaults = .standard
    ) {
        guard progress.isFinite, progress > 0, let (kind, id) = decompose(ref) else { return }
        let storageKey = prefix + key(profile(profileID), kind, id)
        let value = [progress, duration, recordedAt.timeIntervalSince1970]
        // UserDefaults is thread-safe; the SDK just doesn't mark it Sendable.
        nonisolated(unsafe) let defaults = defaults
        let write: @Sendable () -> Void = {
            guard lastProgress[storageKey] != progress else { return }
            lastProgress[storageKey] = progress
            defaults.set(value, forKey: storageKey)
        }
        if waitUntilWritten { queue.sync(execute: write) } else { queue.async(execute: write) }
    }

    /// Drop the buffered entry for `ref` once it has reached SwiftData.
    static func remove(ref: PlayableMedia.ContentRef, profileID: UUID?, defaults: UserDefaults = .standard) {
        guard let (kind, id) = decompose(ref) else { return }
        let storageKey = prefix + key(profile(profileID), kind, id)
        nonisolated(unsafe) let defaults = defaults
        queue.async {
            lastProgress[storageKey] = nil
            defaults.removeObject(forKey: storageKey)
        }
    }

    /// Read and clear the buffered entries for `profileID`, leaving other
    /// profiles' for when they are active. Synchronous on `queue`, so it can't
    /// race an in-flight `record` or `remove`.
    static func drain(profileID: UUID?, defaults: UserDefaults = .standard) -> [Entry] {
        let wanted = profile(profileID)
        return queue.sync {
            var entries: [Entry] = []
            for (storageKey, value) in defaults.dictionaryRepresentation() where storageKey.hasPrefix(prefix) {
                guard let parsed = parse(String(storageKey.dropFirst(prefix.count))), parsed.profile == wanted else { continue }
                defaults.removeObject(forKey: storageKey)
                lastProgress[storageKey] = nil
                guard let values = value as? [Double], values.count == 3 else { continue }
                entries.append(Entry(
                    profile: parsed.profile, kind: parsed.kind, id: parsed.id, progress: values[0], duration: values[1],
                    recordedAt: Date(timeIntervalSince1970: values[2])
                ))
            }
            return entries
        }
    }

    private static func profile(_ id: UUID?) -> String {
        (id ?? UserProfile.defaultProfileID).uuidString
    }

    private static func decompose(_ ref: PlayableMedia.ContentRef) -> (Kind, String)? {
        switch ref {
        case let .movie(id): (.movie, id)
        case let .episode(id): (.episode, id)
        case .live: nil
        }
    }

    private static func key(_ profile: String, _ kind: Kind, _ id: String) -> String {
        "\(profile):\(kind.rawValue):\(id)"
    }

    /// `profile:kind:id`; the id may itself contain colons.
    private static func parse(_ suffix: String) -> (profile: String, kind: Kind, id: String)? {
        let parts = suffix.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let kind = Kind(rawValue: String(parts[1])) else { return nil }
        return (String(parts[0]), kind, String(parts[2]))
    }
}
