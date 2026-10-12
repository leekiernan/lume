import Foundation
@testable import Lume
import Testing

/// When cards and match centres say a game is.
struct SportsFixtureWhenTests {
    private let calendar = Calendar.current
    /// Midday, so whole-day offsets never cross into another day.
    private var now: Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_791_633_600)) ?? Date()
    }

    private func fixture(inDays days: Int, tentative: Bool? = nil) -> SportsFixture {
        let start = calendar.date(byAdding: .day, value: days, to: now)?.addingTimeInterval(30 * 60) ?? now
        return SportsFixture(
            id: "f", leagueId: "soccer/eng.1", leagueName: "EPL", leagueAbbreviation: "EPL", startDate: start,
            status: SportsFixtureStatus(state: .scheduled), startTimeIsTentative: tentative
        )
    }

    @Test func `cards name the day only when it isn't today, and the date beyond a week`() {
        let today = fixture(inDays: 0)
        #expect(today.cardWhenText(now: now) == today.headlineDate.formatted(.dateTime.hour().minute()))
        #expect(today.cardDayText(now: now) == nil)
        let saturday = fixture(inDays: 4)
        #expect(saturday.cardWhenText(now: now) == saturday.headlineDate.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
        #expect(saturday.cardDayText(now: now) == saturday.headlineDate.formatted(.dateTime.weekday(.abbreviated)))
        // A team's fixtures weeks out: a weekday alone would repeat.
        let later = fixture(inDays: 20)
        #expect(later.cardWhenText(now: now) == later.headlineDate.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
        #expect(later.cardDayText(now: now) == later.headlineDate.formatted(.dateTime.day().month(.abbreviated)))
        #expect(fixture(inDays: 20, tentative: true).cardWhenText(now: now)
            == later.headlineDate.formatted(.dateTime.day().month(.abbreviated)))
    }

    @Test func `the match centre says today, tomorrow, or the date and how far off`() {
        #expect(fixture(inDays: 0).kickoffDayText(now: now) == String(localized: "Today"))
        #expect(fixture(inDays: 1).kickoffDayText(now: now) == String(localized: "Tomorrow"))
        let later = fixture(inDays: 5)
        let date = later.headlineDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        #expect(later.kickoffDayText(now: now) == String(localized: "\(date) · in \(5) days"))
        // A postponed game whose date has passed shows just the date.
        let past = fixture(inDays: -2)
        #expect(past.kickoffDayText(now: now) == past.headlineDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
    }
}
