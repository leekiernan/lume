import Foundation

/// The provider's date queries are UTC, independent of the viewer's calendar.
nonisolated enum SportsFixtureWindow {
    case month(DateComponents)
    case day(Date)

    var interval: DateInterval? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        switch self {
        case let .month(components):
            guard let date = calendar.date(from: components) else { return nil }
            return calendar.dateInterval(of: .month, for: date)
        case let .day(date):
            return calendar.dateInterval(of: .day, for: date)
        }
    }

    func fetch(provider: any SportsDataProvider, league: SportsLeague) async throws -> [SportsFixture] {
        switch self {
        case let .month(month): try await provider.fixtures(league: league, month: month)
        case let .day(day): try await provider.fixtures(league: league, day: day)
        }
    }
}

nonisolated struct SportsFixtureWindowResult {
    let window: SportsFixtureWindow
    let result: Result<[SportsFixture], any Error>

    var succeeded: Bool {
        if case .success = result { return true }
        return false
    }

    /// Only a successful window may replace its cached schedule, including an
    /// empty response. Failed windows and fixtures outside the query survive.
    static func merging(_ results: [Self], into existing: [SportsFixture]) -> [SportsFixture] {
        let intervals = results.filter(\.succeeded).compactMap(\.window.interval)
        let kept = existing.filter { fixture in
            !intervals.contains { fixture.startDate >= $0.start && fixture.startDate < $0.end }
        }
        var byID = Dictionary(kept.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for fetched in results {
            guard case let .success(fixtures) = fetched.result else { continue }
            for fixture in fixtures {
                byID[fixture.id] = fixture
            }
        }
        return Array(byID.values)
    }
}

nonisolated enum SportsFetch {
    static func capture<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async -> Result<Value, any Error> {
        do { return try await .success(operation()) } catch { return .failure(error) }
    }

    static func fixtures(
        provider: any SportsDataProvider, league: SportsLeague, windows: [SportsFixtureWindow]
    ) async -> [SportsFixtureWindowResult] {
        await withTaskGroup(of: (Int, SportsFixtureWindowResult).self) { group in
            for (index, window) in windows.enumerated() {
                group.addTask {
                    let result = await capture { try await window.fetch(provider: provider, league: league) }
                    return (index, SportsFixtureWindowResult(window: window, result: result))
                }
            }
            var results: [Int: SportsFixtureWindowResult] = [:]
            for await (index, result) in group {
                results[index] = result
            }
            return windows.indices.compactMap { results[$0] }
        }
    }
}

nonisolated extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
