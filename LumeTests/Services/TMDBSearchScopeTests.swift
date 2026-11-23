@testable import Lume
import Testing

struct TMDBSearchScopeTests {
    private typealias Counts = TMDBSearchScope.Counts
    /// A provider that supplies ids for nearly everything.
    private let xtream = Counts(total: 167_122, withID: 164_464)

    @Test func `a category the provider gives no ids is not searched`() {
        #expect(!TMDBSearchScope.searches(category: Counts(total: 618, withID: 6), playlist: xtream), "Football Replays")
        #expect(TMDBSearchScope.searches(category: Counts(total: 36440, withID: 36434), playlist: xtream), "Drama")
    }

    @Test func `a small or partly covered category is still searched`() {
        #expect(TMDBSearchScope.searches(category: Counts(total: 12, withID: 0), playlist: xtream))
        #expect(TMDBSearchScope.searches(category: Counts(total: 437, withID: 317), playlist: xtream), "Fighting Replays, 27% missing")
    }

    @Test func `a playlist that carries no ids is searched everywhere`() {
        let m3u = Counts(total: 5000, withID: 0)
        #expect(TMDBSearchScope.searches(category: Counts(total: 600, withID: 0), playlist: m3u))
    }
}
