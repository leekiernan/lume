import Foundation
import OSLog
import SwiftData

/// Owns the local/cloud preferences baseline, import merge, apply suppression
/// and debounced save. ProfileManager owns roster and projection changes, and
/// forwards import/switch events without implementing preference storage.
@MainActor
final class ProfilePreferencesSynchronizer {
    private struct Baseline {
        let snapshot: ProfilePreferencesSnapshot
        let json: String
    }

    private let context: ModelContext
    private let defaults: UserDefaults
    private let currentProfileID: () -> UUID
    private let canSynchronize: () -> Bool
    private let canSeedCloud: () -> Bool
    private let save: () throws -> Void
    private var baseline: Baseline?
    private var isApplyingPreferences = false
    private var saveTask: Task<Void, Never>?
    private nonisolated(unsafe) var observer: NSObjectProtocol?
    private static let saveDelay: Duration = .milliseconds(250)

    init(
        context: ModelContext,
        defaults: UserDefaults = .standard,
        currentProfileID: @escaping () -> UUID,
        canSynchronize: @escaping () -> Bool,
        canSeedCloud: @escaping () -> Bool,
        save: (() throws -> Void)? = nil
    ) {
        self.context = context
        self.defaults = defaults
        self.currentProfileID = currentProfileID
        self.canSynchronize = canSynchronize
        self.canSeedCloud = canSeedCloud
        self.save = save ?? { try context.save() }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesDidChange() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        saveTask?.cancel()
    }

    func activate(for profileID: UUID, allowCloudSeed: Bool) {
        cancelPendingPreferencesSave()
        baseline = nil
        synchronize(for: profileID, allowCloudSeed: allowCloudSeed)
    }

    /// Flush the outgoing profile before the store projection suspends.
    func flush(for profileID: UUID) {
        cancelPendingPreferencesSave()
        persistPreferencesIfChanged(for: profileID)
    }

    private func profile(with id: UUID) -> UserProfile? {
        var query = FetchDescriptor<UserProfile>(predicate: #Predicate { $0.id == id })
        query.fetchLimit = 1
        return try? context.fetch(query).first
    }

    /// First use on a device is asymmetric on purpose: a non-empty CloudKit
    /// snapshot always wins. Existing local values can seed an empty snapshot
    /// only after a successful import has established that the empty field is
    /// current, rather than a stale pre-import copy of another device's profile.
    private func synchronize(
        for profileID: UUID,
        allowCloudSeed: Bool,
        preservingPendingLocalChanges: Bool = false
    ) {
        guard let profile = profile(with: profileID) else { return }
        let local = ProfileScopedPreferences.snapshot(profileID: profileID, defaults: defaults)
        let pendingBaseline = pendingPreferencesBaseline(
            for: local,
            preservingPendingLocalChanges: preservingPendingLocalChanges
        )
        guard !profile.preferencesJSON.isEmpty else {
            synchronizeEmptyPreferences(
                local,
                profile: profile,
                profileID: profileID,
                allowCloudSeed: allowCloudSeed,
                pendingBaseline: pendingBaseline
            )
            return
        }
        guard let imported = ProfileScopedPreferences.decode(profile.preferencesJSON) else {
            Logger.sync.error("Ignoring malformed synced preferences for profile \(profileID.uuidString, privacy: .public)")
            // Keep a pending local change dirty so its debounce can replace the
            // malformed payload with a valid snapshot instead of silently
            // accepting that it was saved.
            guard pendingBaseline == nil else { return }
            baseline = Baseline(snapshot: local, json: profile.preferencesJSON)
            return
        }
        applyImportedPreferences(imported, local: local, pendingBaseline: pendingBaseline, to: profile)
    }

    private func pendingPreferencesBaseline(
        for local: ProfilePreferencesSnapshot,
        preservingPendingLocalChanges: Bool
    ) -> ProfilePreferencesSnapshot? {
        guard preservingPendingLocalChanges,
              let lastPreferencesSnapshot = baseline?.snapshot,
              local != lastPreferencesSnapshot
        else { return nil }
        return lastPreferencesSnapshot
    }

    private func synchronizeEmptyPreferences(
        _ local: ProfilePreferencesSnapshot,
        profile: UserProfile,
        profileID: UUID,
        allowCloudSeed: Bool,
        pendingBaseline: ProfilePreferencesSnapshot?
    ) {
        // A completed import proves the empty payload is current. Preserve an
        // edit made while that import was running by publishing it now. Before
        // completion, leave its debounce task alone rather than treating a
        // possibly-stale empty row as authoritative.
        if pendingBaseline != nil {
            guard allowCloudSeed else { return }
            cancelPendingPreferencesSave()
            persistPreferences(local, to: profile)
            return
        }
        baseline = Baseline(snapshot: local, json: "")
        if ProfileScopedPreferences.shouldSeedCloudSnapshot(
            cloudJSON: profile.preferencesJSON,
            hasCompletedCloudImport: allowCloudSeed,
            hasStoredLocalValues: ProfileScopedPreferences.hasStoredValues(profileID: profileID, defaults: defaults)
        ) {
            persistPreferences(local, to: profile)
        }
    }

    private func applyImportedPreferences(
        _ imported: ProfilePreferencesSnapshot,
        local: ProfilePreferencesSnapshot,
        pendingBaseline: ProfilePreferencesSnapshot?,
        to profile: UserProfile
    ) {
        let resolved = if let pendingBaseline {
            ProfileScopedPreferences.merging(
                remote: imported,
                withLocalChanges: local,
                since: pendingBaseline
            )
        } else {
            imported
        }
        if pendingBaseline != nil {
            cancelPendingPreferencesSave()
        }
        isApplyingPreferences = true
        ProfileScopedPreferences.apply(resolved, profileID: profile.id, defaults: defaults)
        isApplyingPreferences = false
        let applied = ProfileScopedPreferences.snapshot(profileID: profile.id, defaults: defaults)
        if pendingBaseline != nil {
            // Publish the merged document so the local edit travels to the other
            // devices as well. `persistPreferences` retains remote fields from a
            // newer app version that this build does not understand.
            persistPreferences(applied, to: profile)
        } else {
            baseline = Baseline(snapshot: applied, json: profile.preferencesJSON)
        }
    }

    private func cancelPendingPreferencesSave() {
        saveTask?.cancel()
        saveTask = nil
    }

    /// A remote-store notification can also concern playlists, Trakt or an
    /// inactive profile. Apply only when the active profile's payload changed.
    func applyImportedPreferencesIfNeeded() {
        guard canSynchronize(),
              let profile = profile(with: currentProfileID()),
              profile.preferencesJSON != baseline?.json
        else { return }
        synchronize(
            for: currentProfileID(),
            allowCloudSeed: canSeedCloud(),
            preservingPendingLocalChanges: true
        )
    }

    func cloudImportDidComplete() {
        guard canSynchronize() else { return }
        synchronize(
            for: currentProfileID(),
            allowCloudSeed: true,
            preservingPendingLocalChanges: true
        )
    }

    func preferencesDidChange() {
        guard canSynchronize(), !isApplyingPreferences else { return }
        let current = ProfileScopedPreferences.snapshot(profileID: currentProfileID(), defaults: defaults)
        guard current != baseline?.snapshot else { return }
        saveTask?.cancel()
        let profileID = currentProfileID()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled, self?.currentProfileID() == profileID, self?.canSynchronize() == true else { return }
            self?.persistPreferencesIfChanged(for: profileID)
        }
    }

    private func persistPreferencesIfChanged(for profileID: UUID) {
        let current = ProfileScopedPreferences.snapshot(profileID: profileID, defaults: defaults)
        guard current != baseline?.snapshot,
              let profile = profile(with: profileID)
        else { return }
        persistPreferences(current, to: profile)
    }

    private func persistPreferences(_ current: ProfilePreferencesSnapshot, to profile: UserProfile) {
        let previous = ProfileScopedPreferences.decode(profile.preferencesJSON)
        let merged = ProfileScopedPreferences.preservingUnknownValues(in: previous, updating: current)
        guard let encoded = ProfileScopedPreferences.encode(merged) else { return }
        guard encoded != profile.preferencesJSON else {
            baseline = Baseline(snapshot: current, json: encoded)
            return
        }
        let previousJSON = profile.preferencesJSON
        let previousUpdatedAt = profile.updatedAt
        profile.preferencesJSON = encoded
        profile.updatedAt = Date()
        do {
            try save()
            baseline = Baseline(snapshot: current, json: encoded)
        } catch {
            // A failed save must remain dirty. Otherwise the next pass sees
            // the unsaved encoded value and incorrectly calls it persisted.
            // Restore only our fields, not unrelated changes in the context.
            profile.preferencesJSON = previousJSON
            profile.updatedAt = previousUpdatedAt
            Logger.sync.error("Saving synced profile preferences failed: \(error.localizedDescription)")
        }
    }
}
