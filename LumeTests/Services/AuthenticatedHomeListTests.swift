import Foundation
@testable import Lume
import Testing

struct AuthenticatedHomeListTests {
    @Test(arguments: SectionSurface.allCases)
    func `recommendations use the existing section storage and account scoped cache`(_ surface: SectionSurface) {
        let source = AuthenticatedHomeList.traktRecommendations
        let section = source.section(title: "  Suggested for me  ", surface: surface)
        #expect(section.title == "Suggested for me")
        #expect(section.authenticatedList == source)
        #expect(section.provider is TraktListProvider)
        #expect(CustomHomeSections.decode(CustomHomeSections.encode([section])) == [section])
        #expect(CustomHomeSections.accountSignature([section], traktUsername: "a") != CustomHomeSections.accountSignature([section], traktUsername: "b"))
        let alice = HomeListCacheKey(source: section.sourceURL, account: "a")
        #expect(alice != HomeListCacheKey(source: section.sourceURL, account: "b"))
        #expect(alice != HomeListCacheKey(source: section.sourceURL, account: nil))
    }

    @Test func `each area has its own source, added under the default title`() {
        let source = AuthenticatedHomeList.traktRecommendations
        #expect(Set(SectionSurface.allCases.map(source.sourceURL)).count == 3)
        #expect(source.section(title: "", surface: .home).title == source.defaultTitle)
    }

    @Test func `ordinary Trakt lists and lookalike paths are not authenticated presets`() {
        for url in ["https://trakt.tv/users/me/lists/recommendations", "https://example.com/media/recommendations",
                    "https://api.trakt.tv/media/recommendations/other", "https://api.trakt.tv/media/recommendations?mode=other"]
        {
            #expect(AuthenticatedHomeList.matching(url) == nil)
        }
    }

    @Test func `renaming recommendations does not invalidate their feed`() {
        let section = AuthenticatedHomeList.traktRecommendations.section(title: "One", surface: .home)
        var renamed = section
        renamed.title = "Two"
        #expect(CustomHomeSections.contentSignature([section]) == CustomHomeSections.contentSignature([renamed]))
        #expect(HomeLayoutSettings.resolve(orderRaw: "", custom: [section], surface: .home).contains(.custom(section.id)))
    }
}
