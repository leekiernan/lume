@testable import Lume
import Testing

@MainActor
struct PersonFilmographyLoadMachineTests {
    @Test func `changing visibility revokes a page before credits arrive`() throws {
        var machine = PersonFilmographyLoadMachine()
        let firstRequest = machine.beginCredits(for: "adult")
        let first = try #require(firstRequest)
        let firstAccepted = machine.finishCredits(first, hasEntries: true)
        #expect(firstAccepted)
        let pageRequest = machine.beginPage()
        let page = try #require(pageRequest)
        let replacementRequest = machine.beginCredits(for: "child")
        let replacement = try #require(replacementRequest)
        let staleAccepted = machine.finishPage(page, scanned: 100, hasMore: true)
        let prematurePage = machine.beginPage()
        #expect(!staleAccepted && prematurePage == nil)
        let replacementAccepted = machine.finishCredits(replacement, hasEntries: true)
        let currentPage = machine.beginPage()
        #expect(replacementAccepted && currentPage?.offset == 0)
    }

    @Test func `covered pages resume at their cursor and reject cancelled completions`() throws {
        var machine = PersonFilmographyLoadMachine()
        let creditsRequest = machine.beginCredits(for: "person")
        let credits = try #require(creditsRequest)
        let creditsAccepted = machine.finishCredits(credits, hasEntries: true)
        #expect(creditsAccepted)
        let firstRequest = machine.beginPage()
        let first = try #require(firstRequest)
        let firstAccepted = machine.finishPage(first, scanned: 100, hasMore: true)
        #expect(firstAccepted)
        let cancelledRequest = machine.beginPage()
        let cancelled = try #require(cancelledRequest)
        machine.cancelPage()
        let cachedCredits = machine.beginCredits(for: "person")
        #expect(cachedCredits == nil)
        let resumedRequest = machine.beginPage()
        let resumed = try #require(resumedRequest)
        #expect(resumed.offset == 100)
        let cancelledAccepted = machine.finishPage(cancelled, scanned: 100, hasMore: false)
        let resumedAccepted = machine.finishPage(resumed, scanned: 100, hasMore: false)
        #expect(!cancelledAccepted && resumedAccepted)
    }

    @Test func `restarted credits own their completion and empty results exhaust paging`() throws {
        var machine = PersonFilmographyLoadMachine()
        let oldRequest = machine.beginCredits(for: "person")
        let old = try #require(oldRequest)
        let currentRequest = machine.beginCredits(for: "person")
        let current = try #require(currentRequest)
        machine.abandonCredits(old)
        let oldAccepted = machine.finishCredits(old, hasEntries: true)
        let currentAccepted = machine.finishCredits(current, hasEntries: false)
        #expect(!oldAccepted && currentAccepted)
        #expect(!machine.isLoadingCredits)
        let page = machine.beginPage()
        #expect(page == nil)
    }
}
