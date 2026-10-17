import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct ProfilePreferencesSynchronizerTests {
    @Test func `failed saves remain dirty and retry without changing unrelated fields`() throws {
        let fixture = try PreferencesFixture()
        defer { fixture.cleanUp() }
        fixture.synchronizer.activate(for: fixture.scope.profileID, allowCloudSeed: true)
        let previousJSON = fixture.profile.preferencesJSON
        let previousUpdatedAt = fixture.profile.updatedAt
        fixture.setOrder("favorites")
        fixture.profile.name = "Edited name"
        fixture.scope.failSave = true
        fixture.synchronizer.flush(for: fixture.scope.profileID)
        #expect(fixture.profile.preferencesJSON == previousJSON)
        #expect(fixture.profile.updatedAt == previousUpdatedAt)
        #expect(fixture.profile.name == "Edited name")
        fixture.scope.failSave = false
        fixture.synchronizer.flush(for: fixture.scope.profileID)
        #expect(try fixture.saved().strings[fixture.orderKey] == "favorites")
        #expect(fixture.scope.saveAttempts == 2)
    }

    @Test func `an empty cloud row waits for a completed import before seeding`() throws {
        let fixture = try PreferencesFixture()
        defer { fixture.cleanUp() }
        fixture.setOrder("favorites")
        fixture.synchronizer.activate(for: fixture.scope.profileID, allowCloudSeed: false)
        #expect(fixture.profile.preferencesJSON.isEmpty)
        fixture.synchronizer.cloudImportDidComplete()
        #expect(try fixture.saved().strings[fixture.orderKey] == "favorites")
    }

    @Test func `remote import merges pending edits and preserves unknown fields`() throws {
        let fixture = try PreferencesFixture()
        defer { fixture.cleanUp() }
        var original = fixture.snapshot()
        original.strings[fixture.orderKey] = "favorites"
        fixture.profile.preferencesJSON = try #require(ProfileScopedPreferences.encode(original))
        fixture.synchronizer.activate(for: fixture.scope.profileID, allowCloudSeed: true)
        fixture.setOrder("forYou,favorites")
        fixture.synchronizer.preferencesDidChange()
        var remote = original
        remote.strings[AppAreaSettings.baseDisabledAreasKey] = "liveTV"
        remote.strings["future.preference"] = "retain"
        fixture.profile.preferencesJSON = try #require(ProfileScopedPreferences.encode(remote))
        fixture.synchronizer.cloudImportDidComplete()
        let saved = try fixture.saved()
        #expect(saved.strings[fixture.orderKey] == "forYou,favorites")
        #expect(saved.strings[AppAreaSettings.baseDisabledAreasKey] == "liveTV")
        #expect(saved.strings["future.preference"] == "retain")
        #expect(fixture.snapshot().strings[AppAreaSettings.baseDisabledAreasKey] == "liveTV")
        let updatedAt = fixture.profile.updatedAt
        fixture.synchronizer.flush(for: fixture.scope.profileID)
        #expect(fixture.profile.updatedAt == updatedAt) // No import/save echo.
    }

    @Test func `switch flushes outgoing edits and resets the incoming baseline`() throws {
        let fixture = try PreferencesFixture()
        defer { fixture.cleanUp() }
        fixture.synchronizer.activate(for: fixture.scope.profileID, allowCloudSeed: true)
        fixture.setOrder("favorites")
        fixture.synchronizer.preferencesDidChange()
        let outgoing = fixture.scope.profileID
        fixture.synchronizer.flush(for: outgoing)
        let other = UserProfile(name: "Other")
        fixture.context.insert(other)
        try fixture.context.save()
        fixture.scope.profileID = other.id
        fixture.synchronizer.activate(for: other.id, allowCloudSeed: true)
        #expect(fixture.snapshot().strings[fixture.orderKey] == "")
        #expect(other.preferencesJSON.isEmpty) // A new profile does not inherit the old one.
        fixture.setOrder("trendingMovies")
        fixture.synchronizer.flush(for: other.id)
        #expect(try fixture.saved().strings[fixture.orderKey] == "favorites")
        let incoming = try #require(ProfileScopedPreferences.decode(other.preferencesJSON))
        #expect(incoming.strings[fixture.orderKey] == "trendingMovies")
    }

    @Test func `malformed imports do not discard a pending local change`() throws {
        let fixture = try PreferencesFixture()
        defer { fixture.cleanUp() }
        fixture.profile.preferencesJSON = try #require(ProfileScopedPreferences.encode(fixture.snapshot()))
        fixture.synchronizer.activate(for: fixture.scope.profileID, allowCloudSeed: true)
        fixture.setOrder("favorites")
        fixture.synchronizer.preferencesDidChange()
        fixture.profile.preferencesJSON = "not JSON"
        fixture.synchronizer.applyImportedPreferencesIfNeeded()
        fixture.synchronizer.flush(for: fixture.scope.profileID)
        #expect(try fixture.saved().strings[fixture.orderKey] == "favorites")
    }

    @Test func `notifications during projection cannot apply another profile's preferences`() throws {
        let fixture = try PreferencesFixture()
        defer { fixture.cleanUp() }
        fixture.synchronizer.activate(for: fixture.scope.profileID, allowCloudSeed: true)
        fixture.scope.canSynchronize = false
        var remote = fixture.snapshot()
        remote.strings[fixture.orderKey] = "remote"
        fixture.profile.preferencesJSON = try #require(ProfileScopedPreferences.encode(remote))
        fixture.synchronizer.applyImportedPreferencesIfNeeded()
        fixture.synchronizer.cloudImportDidComplete()
        #expect(fixture.snapshot().strings[fixture.orderKey] == "")
        fixture.scope.canSynchronize = true
        fixture.synchronizer.applyImportedPreferencesIfNeeded()
        #expect(fixture.snapshot().strings[fixture.orderKey] == "remote")
    }
}

@MainActor
private final class PreferencesTestScope {
    var profileID: UUID
    var canSynchronize = true
    var failSave = false
    var saveAttempts = 0
    init(profileID: UUID) {
        self.profileID = profileID
    }
}

@MainActor
private final class PreferencesFixture {
    let suite = "ProfilePreferencesSynchronizerTests.\(UUID())"
    let defaults: UserDefaults
    let container: ModelContainer
    var context: ModelContext {
        container.mainContext
    }

    let profile = UserProfile(name: "Viewer")
    let scope: PreferencesTestScope
    let synchronizer: ProfilePreferencesSynchronizer
    let orderKey = HomeLayoutSettings.baseSectionOrderKey(.home)

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        let schema = Schema([UserProfile.self])
        container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        ])
        container.mainContext.autosaveEnabled = false
        container.mainContext.insert(profile)
        try container.mainContext.save()
        let scope = PreferencesTestScope(profileID: profile.id)
        self.scope = scope
        let context = container.mainContext
        synchronizer = ProfilePreferencesSynchronizer(
            context: container.mainContext, defaults: defaults,
            currentProfileID: { scope.profileID }, canSynchronize: { scope.canSynchronize }, canSeedCloud: { true },
            save: {
                scope.saveAttempts += 1
                if scope.failSave { throw PreferencesTestError.forced }
                try context.save()
            }
        )
    }

    func setOrder(_ value: String) {
        defaults.set(value, forKey: ProfileScopedPreferences.key(orderKey, profileID: scope.profileID))
    }

    func snapshot() -> ProfilePreferencesSnapshot {
        ProfileScopedPreferences.snapshot(profileID: scope.profileID, defaults: defaults)
    }

    func saved() throws -> ProfilePreferencesSnapshot {
        try #require(ProfileScopedPreferences.decode(profile.preferencesJSON))
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
    }
}

private nonisolated enum PreferencesTestError: Error { case forced }
