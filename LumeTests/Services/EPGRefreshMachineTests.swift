@testable import Lume
import Testing

struct EPGRefreshMachineTests {
    @Test func `metadata deferred by a VOD sync remains metadata only`() throws {
        var machine = EPGRefreshMachine()
        let transition1 = machine.contentSyncStarted()
        #expect(!transition1)
        #expect(machine.begin(.enrichment, mode: .background) == nil)
        machine.contentSyncFinished(succeeded: true, refreshedLiveTV: false)
        let job = try #require(machine.begin(.enrichment, mode: .background))
        #expect(job.intent == .enrichment)
        #expect(machine.pendingIntent == nil)
    }

    @Test func `a successful live sync upgrades metadata debt to provider work`() throws {
        var machine = EPGRefreshMachine()
        machine.isAutoSyncQueued = true
        machine.owe(.enrichment)
        let transition2 = machine.contentSyncStarted()
        #expect(!transition2)
        machine.contentSyncFinished(succeeded: true, refreshedLiveTV: true)
        #expect(machine.begin(.enrichment, mode: .background) == nil)
        machine.isAutoSyncQueued = false
        let job = try #require(machine.begin(.enrichment, mode: .background))
        #expect(job.intent == .guide(allowConditional: true))
    }

    @Test(arguments: [EPGRefreshIntent.enrichment, .guide(allowConditional: true), .guide(allowConditional: false)])
    func `content sync cancellation retains the exact running intent`(_ intent: EPGRefreshIntent) throws {
        var machine = EPGRefreshMachine()
        let first = try #require(machine.begin(intent, mode: .background))
        let transition3 = machine.contentSyncStarted()
        #expect(transition3)
        #expect(machine.pendingIntent == intent)
        machine.contentSyncFinished(succeeded: false, refreshedLiveTV: false)
        #expect(machine.begin(.enrichment, mode: .background) == nil) // Old task must finish first.
        let transition4 = machine.finish(first)
        #expect(transition4)
        let next = try #require(machine.begin(.enrichment, mode: .background))
        #expect(next.intent == intent)
        let transition5 = machine.finish(first)
        #expect(!transition5)
        #expect(machine.running == next)
    }

    @Test func `manual work remains admitted and is not cancelled by content sync`() throws {
        var machine = EPGRefreshMachine()
        let transition6 = machine.contentSyncStarted()
        #expect(!transition6)
        machine.owe(.enrichment)
        let job = try #require(machine.begin(.guide(allowConditional: false), mode: .manual))
        let transition7 = machine.contentSyncStarted()
        #expect(!transition7)
        #expect(machine.pendingIntent == nil)
        #expect(job.intent == .guide(allowConditional: false))
    }

    @Test func `changes during a refresh remain owed after it finishes`() throws {
        var machine = EPGRefreshMachine()
        let job = try #require(machine.begin(.guide(allowConditional: true), mode: .background))
        machine.owe(.enrichment)
        let transition8 = machine.finish(job)
        #expect(transition8)
        #expect(machine.pendingIntent == .enrichment)
        let next = try #require(machine.begin(.enrichment, mode: .background))
        #expect(next.intent == .enrichment)
    }

    @Test func `forced guide debt dominates in either arrival order`() {
        let forced = EPGRefreshIntent.guide(allowConditional: false)
        let conditional = EPGRefreshIntent.guide(allowConditional: true)
        #expect(forced.merging(.enrichment) == forced)
        #expect(EPGRefreshIntent.enrichment.merging(forced) == forced)
        #expect(conditional.merging(forced) == forced)
        #expect(forced.merging(conditional) == forced)
    }
}
