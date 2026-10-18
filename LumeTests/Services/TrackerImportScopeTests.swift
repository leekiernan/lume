import Foundation
@testable import Lume
import Testing

/// Fetched tracker history is applied only to the account and profile it was
/// fetched for, with nothing local still waiting to go up.
struct TrackerImportScopeTests {
    @Test func `import and parked progress share the same authorization identity`() {
        let importScope = TrackerScope(account: "a", profileID: profile)
        let parked = TrackerScope(profileID: profile, accountID: "a")
        #expect(importScope == parked)
        #expect(importScope.matches(parked))
        for account in [nil, ""] as [String?] {
            let missing = TrackerScope(account: account, profileID: profile)
            #expect(!missing.isCurrent(isConnected: true, account: account, pendingCount: 0, profileID: profile))
            #expect(!missing.matches(missing))
        }
    }

    private let profile = UUID()
    private var scope: TrackerScope {
        TrackerScope(account: "a", profileID: profile)
    }

    @Test func `unchanged scope may apply`() {
        #expect(scope.isCurrent(isConnected: true, account: "a", pendingCount: 0, profileID: profile))
    }

    @Test func `a disconnect or another account during the import discards it`() {
        #expect(!scope.isCurrent(isConnected: false, account: "a", pendingCount: 0, profileID: profile))
        #expect(!scope.isCurrent(isConnected: true, account: "b", pendingCount: 0, profileID: profile))
    }

    @Test func `a profile switch during the import discards it`() {
        #expect(!scope.isCurrent(isConnected: true, account: "a", pendingCount: 0, profileID: UUID()))
    }

    @Test func `a local change made during the import discards it`() {
        #expect(!scope.isCurrent(isConnected: true, account: "a", pendingCount: 1, profileID: profile))
    }
}

/// The shared import sequence, with the scope moving while the fetch runs.
@MainActor
@Suite(.serialized, .globalState)
struct TrackerImportRunTests {
    /// A tracker's live state, as the services read it at the recheck.
    private final class Live {
        var connected = true
        var account: String? = "a"
        var pending = 0
        var fetches = 0
        var applied: [UUID?] = []
    }

    private func run(_ live: Live, scope: TrackerScope? = nil, token: String? = "t",
                     duringFetch: @escaping () -> Void = {}, duringToken: @escaping () -> Void = {}) async -> TrackerImportOutcome<Int>
    {
        let profile = ActiveProfileStore.current
        return await TrackerImportRun(
            permit: TrackerImportPermit(account: TrackerAccountLifetime()),
            begin: { scope ?? TrackerScope(account: live.account, profileID: profile) },
            accessToken: { duringToken(); return token },
            fetch: { _ in
                live.fetches += 1
                duringFetch()
                return 3
            },
            isCurrent: { $0.isCurrent(isConnected: live.connected, account: live.account, pendingCount: live.pending) },
            apply: { items, scope, _ in
                live.applied.append(scope.profileID)
                return items
            }
        ).perform()
    }

    @Test func `an unchanged scope applies under the profile it was fetched for`() async {
        let live = Live()
        guard case let .applied(count) = await run(live) else { Issue.record("not applied"); return }
        #expect(count == 3)
        #expect(live.applied == [ActiveProfileStore.current])
    }

    @Test func `pending local changes defer the import before any fetch`() async {
        let live = Live()
        let outcome = await TrackerImportRun<Int, Int>(
            permit: TrackerImportPermit(account: TrackerAccountLifetime()),
            begin: { nil }, accessToken: { "t" },
            fetch: { _ in live.fetches += 1; return 0 }, isCurrent: { _ in true }, apply: { items, _, _ in items }
        ).perform()
        guard case .deferred = outcome else { Issue.record("not deferred"); return }
        #expect(live.fetches == 0)
    }

    @Test func `a disconnect, another account or a local change during the fetch discards it`() async {
        for change in [{ (live: Live) in live.connected = false }, { $0.account = "b" }, { $0.pending = 1 }] {
            let live = Live()
            guard case .discarded = await run(live, duringFetch: { change(live) }) else { Issue.record("not discarded"); continue }
            #expect(live.applied.isEmpty)
        }
    }

    @Test func `a profile switch during the fetch discards it`() async {
        let saved = ActiveProfileStore.current
        defer { ActiveProfileStore.current = saved }
        ActiveProfileStore.current = UUID()
        let live = Live()
        guard case .discarded = await run(live, duringFetch: { ActiveProfileStore.current = UUID() }) else {
            Issue.record("not discarded")
            return
        }
        #expect(live.applied.isEmpty)
    }

    @Test func `no token fails without fetching`() async {
        let live = Live()
        guard case .failed = await run(live, token: nil) else { Issue.record("not failed"); return }
        #expect(live.fetches == 0)
    }

    @Test func `returning to the same profile cannot revive fetched history`() async {
        let saved = ActiveProfileStore.current
        defer { ActiveProfileStore.current = saved }
        let profile = UUID()
        ActiveProfileStore.current = profile
        let live = Live()
        let outcome = await run(live, duringFetch: {
            ActiveProfileStore.current = UUID()
            ActiveProfileStore.current = profile
        })
        guard case .discarded = outcome else { Issue.record("retired import revived"); return }
        #expect(live.applied.isEmpty)
    }

    @Test func `scope is rechecked after waiting for an access token before downloading history`() async {
        let saved = ActiveProfileStore.current
        defer { ActiveProfileStore.current = saved }
        let live = Live()
        guard case .discarded = await run(live, duringToken: { ActiveProfileStore.current = UUID() }) else {
            Issue.record("not discarded")
            return
        }
        #expect(live.fetches == 0)
    }

    @Test func `a reconnect to the same account retires its in-flight import`() async {
        let account = TrackerAccountLifetime()
        let permit = TrackerImportPermit(account: account)
        let scope = TrackerScope(account: "same-account", profileID: ActiveProfileStore.current)
        var applied = false
        let outcome = await TrackerImportRun<Int, Int>(
            permit: permit, begin: { scope }, accessToken: { "fixture" },
            fetch: { _ in account.invalidate(); return 1 }, isCurrent: { _ in true },
            apply: { items, _, _ in applied = true; return items }
        ).perform()
        guard case .discarded = outcome else { Issue.record("retired account revived"); return }
        #expect(!applied)
        #expect(permit.withCurrent { true } == nil)
        #expect(TrackerImportPermit(account: account).isCurrent)
    }

    @Test(.trackerIdentity(.simkl))
    func `simkl apply refuses a profile other than the one fetched for`() async throws {
        let saved = ActiveProfileStore.current
        defer { ActiveProfileStore.current = saved }
        ActiveProfileStore.current = UUID()
        let account = try #require(SimklAccountIdentityStore.load()?.scope)
        let summary = try await SimklService.applyImport(
            items: SimklAllItems(movies: [], shows: []), container: makeTestContainer(), scope: .init(profileID: UUID(), accountID: account),
            permit: TrackerImportPermit(account: TrackerAccountLifetime())
        )
        #expect(summary.failed)
    }

    @Test(.trackerIdentity(.simkl))
    func `simkl apply accepts the matching account and profile`() async throws {
        let saved = ActiveProfileStore.current
        defer { ActiveProfileStore.current = saved }
        ActiveProfileStore.current = UUID()
        let account = try #require(SimklAccountIdentityStore.load()?.scope)
        let summary = try await SimklService.applyImport(
            items: SimklAllItems(movies: [], shows: []), container: makeTestContainer(),
            scope: .init(profileID: ActiveProfileStore.current, accountID: account), permit: TrackerImportPermit(account: TrackerAccountLifetime())
        )
        #expect(!summary.failed)
    }

    @Test(.trackerIdentity(.simkl))
    func `simkl apply refuses a changed or missing account under the matching profile`() async throws {
        let saved = ActiveProfileStore.current
        defer { ActiveProfileStore.current = saved }
        ActiveProfileStore.current = UUID()
        let account = try #require(SimklAccountIdentityStore.load()?.scope)
        let container = try makeTestContainer()
        for accountID in ["another-account", nil] as [String?] {
            let summary = await SimklService.applyImport(
                items: SimklAllItems(movies: [], shows: []), container: container,
                scope: .init(profileID: ActiveProfileStore.current, accountID: accountID), permit: TrackerImportPermit(account: TrackerAccountLifetime())
            )
            #expect(summary.failed)
        }
        SimklAccountIdentityStore.clear()
        let disconnected = await SimklService.applyImport(
            items: SimklAllItems(movies: [], shows: []), container: container,
            scope: .init(profileID: ActiveProfileStore.current, accountID: account), permit: TrackerImportPermit(account: TrackerAccountLifetime())
        )
        #expect(disconnected.failed)
    }
}
