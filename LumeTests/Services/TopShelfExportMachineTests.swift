@testable import Lume
import Testing

@MainActor
struct TopShelfExportMachineTests {
    @Test func `only the latest request can become ready and publish`() {
        var machine = TopShelfExportMachine()
        let old = machine.request()
        let current = machine.request()
        machine.ready(old)
        #expect(machine.begin() == nil)
        machine.ready(current)
        #expect(machine.begin() == current)
        #expect(machine.canPublish(current))
        let newer = machine.request()
        #expect(!machine.canPublish(current))
        machine.finish(old)
        #expect(machine.begin() == nil)
        machine.ready(newer)
        machine.finish(current)
        #expect(machine.begin() == newer)
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
        #expect(machine.begin() == active)
        _ = machine.request()
        #expect(!machine.canPublish(active))
        machine.finish(active)
        #expect(machine.begin() == nil)
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
