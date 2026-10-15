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
}
