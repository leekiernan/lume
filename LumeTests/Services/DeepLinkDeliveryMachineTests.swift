import Foundation
@testable import Lume
import Testing

struct DeepLinkDeliveryMachineTests {
    private let url = URL(string: "lume://play/movie/title")!
    private let ready = DeepLinkDeliveryMachine.Readiness(profileReady: true, catalogReady: true, presentationBlocked: false)

    @Test func `cold links wait for both profile bootstrap and catalogue recovery`() throws {
        var machine = DeepLinkDeliveryMachine()
        machine.receive(url)
        let token = machine.pendingToken
        let beforeProfile = machine.begin(when: .init(profileReady: false, catalogReady: true, presentationBlocked: false))
        let beforeCatalog = machine.begin(when: .init(profileReady: true, catalogReady: false, presentationBlocked: false))
        #expect(beforeProfile == nil && beforeCatalog == nil)
        #expect(machine.pendingToken == token)
        let started = machine.begin(when: ready)
        let request = try #require(started)
        #expect(request.url == url)
        let accepted = machine.finish(request, outcome: .handled)
        let repeated = machine.begin(when: ready)
        #expect(accepted && repeated == nil)
    }

    @Test func `blocking covers keep a link pending until dismissed`() throws {
        var machine = DeepLinkDeliveryMachine()
        machine.receive(url)
        let blocked = machine.begin(when: .init(profileReady: true, catalogReady: true, presentationBlocked: true))
        #expect(blocked == nil)
        let started = machine.begin(when: ready)
        let request = try #require(started)
        let accepted = machine.finish(request, outcome: .rejected)
        #expect(accepted)
        #expect(machine.pendingToken == nil)
    }

    @Test func `a repeated URL has new ownership and rejects the old completion`() throws {
        var machine = DeepLinkDeliveryMachine()
        machine.receive(url)
        let oldRequest = machine.begin(when: ready)
        let old = try #require(oldRequest)
        machine.receive(url)
        let staleAccepted = machine.finish(old, outcome: .handled)
        #expect(!staleAccepted)
        let currentRequest = machine.begin(when: ready)
        let current = try #require(currentRequest)
        #expect(current != old)
        let currentAccepted = machine.finish(current, outcome: .handled)
        #expect(currentAccepted)
    }

    /// A sync doesn't hold a link back: the catalogue is browsable while it
    /// runs, and a full sync takes minutes.
    @Test func `a running sync doesn't hold a link back`() {
        var machine = DeepLinkDeliveryMachine()
        machine.receive(url)
        let syncing = DeepLinkDeliveryMachine.Readiness(
            profileReady: true, catalogReady: true, presentationBlocked: false, catalogSyncing: true
        )
        let started = machine.begin(when: syncing)
        #expect(started != nil)
    }

    /// A link the catalogue doesn't have yet waits while a sync could still
    /// bring it in, and is tried again once the sync ends.
    @Test func `a link not yet in the catalogue waits for the sync`() throws {
        var machine = DeepLinkDeliveryMachine()
        machine.receive(url)
        let token = machine.pendingToken
        let started = machine.begin(when: ready)
        let first = try #require(started)
        let settled = machine.finish(first, outcome: .rejected, whileSyncing: true)
        #expect(!settled)
        #expect(machine.pendingToken == token)

        let retried = machine.begin(when: ready)
        let second = try #require(retried)
        let finished = machine.finish(second, outcome: .rejected)
        #expect(finished)
        #expect(machine.pendingToken == nil)
    }
}
