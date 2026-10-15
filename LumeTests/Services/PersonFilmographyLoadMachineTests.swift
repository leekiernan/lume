@testable import Lume
import Testing

struct PersonFilmographyLoadMachineTests {
    @Test func `changing visibility revokes a page before credits arrive`() throws {
        var machine = PersonFilmographyLoadMachine()
        let first = try #require(machine.beginCredits(for: "adult"))
        #expect(machine.finishCredits(first, hasEntries: true))
        let page = try #require(machine.beginPage())
        let replacement = try #require(machine.beginCredits(for: "child"))
        #expect(!machine.finishPage(page, scanned: 100, hasMore: true))
        #expect(machine.beginPage() == nil)
        #expect(machine.finishCredits(replacement, hasEntries: true))
        #expect(machine.beginPage()?.offset == 0)
    }

    @Test func `covered pages resume at their cursor and reject cancelled completions`() throws {
        var machine = PersonFilmographyLoadMachine()
        let credits = try #require(machine.beginCredits(for: "person"))
        #expect(machine.finishCredits(credits, hasEntries: true))
        let first = try #require(machine.beginPage())
        #expect(machine.finishPage(first, scanned: 100, hasMore: true))
        let cancelled = try #require(machine.beginPage())
        machine.cancelPage()
        #expect(machine.beginCredits(for: "person") == nil)
        let resumed = try #require(machine.beginPage())
        #expect(resumed.offset == 100)
        #expect(!machine.finishPage(cancelled, scanned: 100, hasMore: false))
        #expect(machine.finishPage(resumed, scanned: 100, hasMore: false))
    }

    @Test func `restarted credits own their completion and empty results exhaust paging`() throws {
        var machine = PersonFilmographyLoadMachine()
        let old = try #require(machine.beginCredits(for: "person"))
        let current = try #require(machine.beginCredits(for: "person"))
        machine.abandonCredits(old)
        #expect(!machine.finishCredits(old, hasEntries: true))
        #expect(machine.finishCredits(current, hasEntries: false))
        #expect(!machine.isLoadingCredits)
        #expect(machine.beginPage() == nil)
    }
}
