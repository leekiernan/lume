@testable import Lume
import Testing

struct EPGRefreshMachineTests {
    @Test func `metadata deferred by a VOD sync remains metadata only`() throws {
        var machine = EPGRefreshMachine()
        let cancelsRunning = machine.contentSyncStarted()
        #expect(!cancelsRunning)
        let begun = machine.begin(.enrichment, mode: .background)
        #expect(begun == nil)
        machine.contentSyncFinished(succeeded: true, refreshedLiveTV: false)
        let begun2 = machine.begin(.enrichment, mode: .background)
        let job = try #require(begun2)
        #expect(job.intent == .enrichment)
        #expect(machine.pendingIntent == nil)
    }

    @Test func `a successful live sync upgrades metadata debt to provider work`() throws {
        var machine = EPGRefreshMachine()
        machine.isAutoSyncQueued = true
        machine.owe(.enrichment)
        let cancelsRunning = machine.contentSyncStarted()
        #expect(!cancelsRunning)
        machine.contentSyncFinished(succeeded: true, refreshedLiveTV: true)
        let begun = machine.begin(.enrichment, mode: .background)
        #expect(begun == nil)
        machine.isAutoSyncQueued = false
        let begun2 = machine.begin(.enrichment, mode: .background)
        let job = try #require(begun2)
        #expect(job.intent == .guide(allowConditional: true))
    }

    @Test(arguments: [EPGRefreshIntent.enrichment, .guide(allowConditional: true), .guide(allowConditional: false)])
    func `content sync cancellation retains the exact running intent`(_ intent: EPGRefreshIntent) throws {
        var machine = EPGRefreshMachine()
        let begun = machine.begin(intent, mode: .background)
        let first = try #require(begun)
        let cancelsRunning = machine.contentSyncStarted()
        #expect(cancelsRunning)
        #expect(machine.pendingIntent == intent)
        machine.contentSyncFinished(succeeded: false, refreshedLiveTV: false)
        let begun2 = machine.begin(.enrichment, mode: .background)
        #expect(begun2 == nil) // Old task must finish first.
        let finished = machine.finish(first)
        #expect(finished)
        let begun3 = machine.begin(.enrichment, mode: .background)
        let next = try #require(begun3)
        #expect(next.intent == intent)
        let finished2 = machine.finish(first)
        #expect(!finished2)
        #expect(machine.running == next)
    }

    @Test func `manual work remains admitted and is not cancelled by content sync`() throws {
        var machine = EPGRefreshMachine()
        let cancelsRunning = machine.contentSyncStarted()
        #expect(!cancelsRunning)
        machine.owe(.enrichment)
        let begun = machine.begin(.guide(allowConditional: false), mode: .manual)
        let job = try #require(begun)
        let cancelsRunning2 = machine.contentSyncStarted()
        #expect(!cancelsRunning2)
        #expect(machine.pendingIntent == nil)
        #expect(job.intent == .guide(allowConditional: false))
    }

    @Test func `changes during a refresh remain owed after it finishes`() throws {
        var machine = EPGRefreshMachine()
        let begun = machine.begin(.guide(allowConditional: true), mode: .background)
        let job = try #require(begun)
        machine.owe(.enrichment)
        let finished = machine.finish(job)
        #expect(finished)
        #expect(machine.pendingIntent == .enrichment)
        let begun2 = machine.begin(.enrichment, mode: .background)
        let next = try #require(begun2)
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
