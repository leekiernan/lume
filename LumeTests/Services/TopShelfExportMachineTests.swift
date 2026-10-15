@testable import Lume
import Testing

@MainActor
struct TopShelfExportMachineTests {
    @Test func `only the latest request can become ready and publish`() {
        var machine = TopShelfExportMachine()
        let old = machine.request()
        let current = machine.request()
        machine.ready(old)
        let premature = machine.begin()
        #expect(premature == nil)
        machine.ready(current)
        let started = machine.begin()
        #expect(started == current)
        #expect(machine.canPublish(current))
        let newer = machine.request()
        #expect(!machine.canPublish(current))
        machine.finish(old)
        let overlapping = machine.begin()
        #expect(overlapping == nil)
        machine.ready(newer)
        machine.finish(current)
        let next = machine.begin()
        #expect(next == newer)
    }

    @Test func `late artwork cannot publish and intermediate exports are dropped`() async {
        let entered = Gate(), release = Gate(), finished = Gate()
        var calls = 0
        var published: [Int] = []
        var oldCheck: TopShelfExportCoordinator.PublicationCheck?
        let coordinator = TopShelfExportCoordinator { check in
            calls += 1
            let call = calls
            if call == 1 {
                oldCheck = check
                entered.open()
                await release.wait()
            }
            if check() { published.append(call) }
            if call == 2 { finished.open() }
        }
        coordinator.refresh(immediately: true)
        await entered.wait()
        coordinator.refresh(immediately: true)
        coordinator.refresh(immediately: true)
        #expect(oldCheck?() == false)
        release.open()
        await finished.wait()
        #expect(calls == 2)
        #expect(published == [2])
    }

    @Test func `immediate background refresh replaces a debounced request`() async {
        let finished = Gate()
        var calls = 0
        let coordinator = TopShelfExportCoordinator(delay: .seconds(60)) { check in
            #expect(check())
            calls += 1
            finished.open()
        }
        coordinator.refresh()
        coordinator.refresh(immediately: true)
        await finished.wait()
        #expect(calls == 1)
    }

    @Test func `profile switch invalidates publication without starting a new export`() {
        var machine = TopShelfExportMachine()
        let active = machine.request()
        machine.ready(active)
        let started = machine.begin()
        #expect(started == active)
        _ = machine.request()
        #expect(!machine.canPublish(active))
        machine.finish(active)
        let pending = machine.begin()
        #expect(pending == nil)
    }
}

@MainActor
private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

/// What lets an export publish: the rows as laid out, not the titles they
/// recorded since (`TopShelfRowPlan.sameLayout`, the refresher's check).
struct TopShelfPublicationEligibilityTests {
    private func row(_ section: HomeSection, _ title: String, recorded: [String] = []) -> TopShelfRowPlan {
        TopShelfRowPlan(source: TopShelfSource(surface: .home, ref: .builtin(section)), title: title, recordedItems: recorded)
    }

    /// Feeds record titles as they load; that must not cost an export its
    /// right to publish.
    @Test func `recorded-title changes keep an export publishable`() {
        let planned = [row(.trendingMovies, "Trending", recorded: ["movie-a"]), row(.favorites, "Favorites")]
        let current = [row(.trendingMovies, "Trending", recorded: ["movie-b", "movie-c"]), row(.favorites, "Favorites", recorded: ["series-x"])]
        #expect(TopShelfRowPlan.sameLayout(planned, current))
    }

    @Test func `removing, adding, reordering or renaming a row invalidates publication`() {
        let trending = row(.trendingMovies, "Trending")
        let favorites = row(.favorites, "Favorites")
        let planned = [trending, favorites]
        #expect(!TopShelfRowPlan.sameLayout(planned, [trending]))
        #expect(!TopShelfRowPlan.sameLayout(planned, [trending, favorites, row(.recentlyAdded, "Recently Added")]))
        #expect(!TopShelfRowPlan.sameLayout(planned, [favorites, trending]))
        #expect(!TopShelfRowPlan.sameLayout(planned, [trending, row(.favorites, "Movies · Favorites")]))
    }
}
