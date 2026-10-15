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
        #expect(machine.begin(when: .init(profileReady: false, catalogReady: true, presentationBlocked: false)) == nil)
        #expect(machine.begin(when: .init(profileReady: true, catalogReady: false, presentationBlocked: false)) == nil)
        #expect(machine.pendingToken == token)
        let request = try #require(machine.begin(when: ready))
        #expect(request.url == url)
        #expect(machine.finish(request, outcome: .handled))
        #expect(machine.begin(when: ready) == nil)
    }

    @Test func `blocking covers keep a link pending until dismissed`() throws {
        var machine = DeepLinkDeliveryMachine()
        machine.receive(url)
        #expect(machine.begin(when: .init(profileReady: true, catalogReady: true, presentationBlocked: true)) == nil)
        let request = try #require(machine.begin(when: ready))
        #expect(machine.finish(request, outcome: .rejected))
        #expect(machine.pendingToken == nil)
    }

    @Test func `a repeated URL has new ownership and rejects the old completion`() throws {
        var machine = DeepLinkDeliveryMachine()
        machine.receive(url)
        let old = try #require(machine.begin(when: ready))
        machine.receive(url)
        #expect(!machine.finish(old, outcome: .handled))
        let current = try #require(machine.begin(when: ready))
        #expect(current != old)
        #expect(machine.finish(current, outcome: .handled))
    }
}
