import Foundation
@testable import Lume
import Testing

@MainActor
struct SectionFeedLoadPlanTests {
    @Test func `custom hero precedes configured rails rather than download arrival order`() {
        let first = CustomHomeSection(title: "First rail", sourceURL: "https://themoviedb.org/list/1")
        let hero = CustomHomeSection(title: "Hero", sourceURL: "https://themoviedb.org/list/2")
        let last = CustomHomeSection(title: "Last rail", sourceURL: "https://themoviedb.org/list/3")
        let plan = SectionFeedLoadPlan(rows: [.custom(first.id), .custom(last.id), .custom(hero.id)],
                                       hero: .custom(hero.id), customSections: [first, last, hero])
        #expect(plan.customSections.map(\.id) == [hero.id, first.id, last.id])
        #expect(plan.jobs == [.custom(hero.id), .custom(first.id), .custom(last.id)])
        #expect(!plan.requests(.trending))
        #expect(!plan.requests(.watchlist(.trakt)))
    }

    @Test func `local rows cost no feed jobs and two trending rows share one job`() {
        let plan = SectionFeedLoadPlan(rows: [.builtin(.continueWatching), .builtin(.trendingMovies), .builtin(.trendingSeries)],
                                       hero: .builtin(.trendingSeries), customSections: [])
        #expect(plan.jobs == [.builtin(.trendingSeries)])
        #expect(plan.requests(.trending))
        #expect(plan.customSections.isEmpty)
    }

    @Test func `empty custom hero settles independently of another loading custom rail`() {
        let hero = HomeSectionRef.custom(UUID())
        let sibling = HomeSectionRef.custom(UUID())
        var machine = SectionFeedLoadMachine()
        _ = machine.handle(.began(.custom, key: "list", cache: .missing))
        _ = machine.handle(.rowBegan(hero, hasCache: false))
        _ = machine.handle(.rowBegan(sibling, hasCache: true))
        _ = machine.handle(.rowFinished(hero, .loaded))
        #expect(machine.heroState(for: hero, hasSlides: false, rowHasItems: false) == .empty)
        #expect(machine.state(of: sibling) == .cached)
        #expect(machine.state(of: SectionFeedSource.custom) == .loading)
    }

    @Test func `skipped sources settle and cannot schedule recovery work`() {
        var machine = SectionFeedLoadMachine()
        _ = machine.handle(.contextChanged(identity: "a"))
        for source in SectionFeedSource.allCases {
            _ = machine.handle(.skipped(source))
        }
        #expect(machine.isSettled)
        #expect(machine.handle(.contextChanged(identity: "b")) == [.discardCatalogModels])
    }
}
