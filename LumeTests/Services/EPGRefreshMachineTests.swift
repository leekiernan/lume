@testable import Lume
import Testing

struct EPGRefreshMachineTests {
    @Test func `metadata deferred by a VOD sync remains metadata only`() throws {
        var machine = EPGRefreshMachine()
        let cancelledRefresh = machine.contentSyncStarted()
        #expect(!cancelledRefresh)
        #expect(machine.begin(.enrichment, mode: .background) == nil)
        machine.contentSyncFinished(succeeded: true, refreshedLiveTV: false)
        let jobRequest = machine.begin(.enrichment, mode: .background)
        let job = try #require(jobRequest)
        #expect(job.intent == .enrichment)
        #expect(machine.pendingIntent == nil)
    }

    @Test func `a successful live sync upgrades metadata debt to provider work`() throws {
        var machine = EPGRefreshMachine()
        machine.isAutoSyncQueued = true
        machine.owe(.enrichment)
        let cancelledRefresh = machine.contentSyncStarted()
        #expect(!cancelledRefresh)
        machine.contentSyncFinished(succeeded: true, refreshedLiveTV: true)
        #expect(machine.begin(.enrichment, mode: .background) == nil)
        machine.isAutoSyncQueued = false
        let jobRequest = machine.begin(.enrichment, mode: .background)
        let job = try #require(jobRequest)
        #expect(job.intent == .guide(allowConditional: true))
    }

    @Test(arguments: [EPGRefreshIntent.enrichment, .guide(allowConditional: true), .guide(allowConditional: false)])
    func `content sync cancellation retains the exact running intent`(_ intent: EPGRefreshIntent) throws {
        var machine = EPGRefreshMachine()
        let firstRequest = machine.begin(intent, mode: .background)
        let first = try #require(firstRequest)
        let cancelledRefresh = machine.contentSyncStarted()
        #expect(cancelledRefresh)
        #expect(machine.pendingIntent == intent)
        machine.contentSyncFinished(succeeded: false, refreshedLiveTV: false)
        #expect(machine.begin(.enrichment, mode: .background) == nil) // Old task must finish first.
        let finished = machine.finish(first)
        #expect(finished)
        let nextRequest = machine.begin(.enrichment, mode: .background)
        let next = try #require(nextRequest)
        #expect(next.intent == intent)
        let staleFinished = machine.finish(first)
        #expect(!staleFinished)
        #expect(machine.running == next)
    }

    @Test func `manual work remains admitted and is not cancelled by content sync`() throws {
        var machine = EPGRefreshMachine()
        let cancelledBeforeManual = machine.contentSyncStarted()
        #expect(!cancelledBeforeManual)
        machine.owe(.enrichment)
        let jobRequest = machine.begin(.guide(allowConditional: false), mode: .manual)
        let job = try #require(jobRequest)
        let cancelledManual = machine.contentSyncStarted()
        #expect(!cancelledManual)
        #expect(machine.pendingIntent == nil)
        #expect(job.intent == .guide(allowConditional: false))
    }

    @Test func `changes during a refresh remain owed after it finishes`() throws {
        var machine = EPGRefreshMachine()
        let jobRequest = machine.begin(.guide(allowConditional: true), mode: .background)
        let job = try #require(jobRequest)
        machine.owe(.enrichment)
        let finished = machine.finish(job)
        #expect(finished)
        #expect(machine.pendingIntent == .enrichment)
        let nextRequest = machine.begin(.enrichment, mode: .background)
        let next = try #require(nextRequest)
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
