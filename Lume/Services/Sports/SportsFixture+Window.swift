//
//  SportsFixture+Window.swift
//  Lume
//
//  How long an event is expected to run, so a day can claim everything that is
//  on during it — not only what started during it. A UFC card that starts at
//  23:00 in the UK and runs into the small hours belongs to tonight's Today
//  after midnight too; bucketing by start alone dropped it into Yesterday while
//  it was still live.
//

import Foundation

nonisolated extension SportsFixture {
    /// A generous typical running time for the sport, used only to decide which
    /// days an event is on during — never shown. Generous, because an event
    /// lingering in Today a little long costs nothing, while one vanishing
    /// mid-event is the bug this exists for.
    var expectedDuration: TimeInterval {
        if let sessionKind {
            return sessionKind == .race ? 2.5 * 3600 : 1.25 * 3600
        }
        switch sport {
        case "soccer", "rugby", "rugby-league": return 2.25 * 3600
        case "basketball", "lacrosse": return 2.75 * 3600
        case "hockey": return 3 * 3600
        case "football", "baseball", "australian-football": return 3.75 * 3600
        case "tennis": return 4 * 3600
        case "cricket": return 8 * 3600
        case "mma", "boxing":
            // Prelims to the end of the main card.
            if let mainCard = mainCardDate { return max(6 * 3600, mainCard.timeIntervalSince(startDate) + 3 * 3600) }
            return 6 * 3600
        case "racing":
            // An unexpanded weekend runs until its race is over.
            if let race = raceSession?.date { return race.timeIntervalSince(startDate) + 2.5 * 3600 }
            return 2.5 * 3600
        default: return 3 * 3600
        }
    }

    /// When the event is expected to be over.
    var expectedEnd: Date {
        startDate.addingTimeInterval(max(expectedDuration, 0))
    }

    /// Whether the event is on at any point inside `range`.
    func isOn(during range: Range<Date>) -> Bool {
        startDate < range.upperBound && expectedEnd > range.lowerBound
    }
}

nonisolated extension SportsFixture {
    /// When a card says a game is: the time alone for today, the weekday and
    /// time within the coming week, so a Saturday kickoff in Thursday's list is
    /// never read as today's, and the date beyond it — a team's fixtures run
    /// for weeks, and a list of "Sat 12:30"s says nothing.
    var cardWhenText: String {
        cardWhenText(now: Date())
    }

    func cardWhenText(now: Date, calendar: Calendar = .current) -> String {
        let days = Self.daysAhead(of: headlineDate, from: now, calendar: calendar)
        let withinWeek = (0 ..< 7).contains(days)
        if startTimeIsTentative == true {
            return headlineDate.formatted(withinWeek ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated))
        }
        if days == 0 { return headlineDate.formatted(.dateTime.hour().minute()) }
        return headlineDate.formatted(withinWeek
            ? .dateTime.weekday(.abbreviated).hour().minute()
            : .dateTime.day().month(.abbreviated).hour().minute())
    }

    /// The day line a card shows above its time: nothing today, the weekday
    /// within the coming week, the date beyond it.
    func cardDayText(now: Date = Date(), calendar: Calendar = .current) -> String? {
        let days = Self.daysAhead(of: headlineDate, from: now, calendar: calendar)
        if days == 0 { return nil }
        return headlineDate.formatted((0 ..< 7).contains(days) ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated))
    }

    /// The day under a match centre's kickoff time: "Today", "Tomorrow", else
    /// the date and how far off it is ("Sat 18 Oct · in 5 days").
    func kickoffDayText(now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = Self.daysAhead(of: headlineDate, from: now, calendar: calendar)
        switch days {
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Tomorrow")
        default:
            let date = headlineDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            return days > 1 ? String(localized: "\(date) · in \(days) days") : date
        }
    }

    /// Calendar days from `now` to `date`: 0 today, 1 tomorrow, negative past.
    private static func daysAhead(of date: Date, from now: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
    }
}
