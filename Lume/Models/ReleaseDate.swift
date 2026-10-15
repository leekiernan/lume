import Foundation

/// A release is a calendar value, not a timestamp. Year-only provider data
/// retains its precision; freshness may estimate a day but display never does.
nonisolated struct ReleaseDate: Hashable, Codable {
    enum Precision { case year, day }

    let year: Int
    let month: Int?
    let day: Int?

    var precision: Precision {
        month == nil ? .year : .day
    }

    init?(year: Int) {
        guard (1 ... 9999).contains(year) else { return nil }
        self.year = year
        month = nil
        day = nil
    }

    init?(year: Int, month: Int, day: Int) {
        guard (1 ... 9999).contains(year), (1 ... 12).contains(month), (1 ... 31).contains(day) else { return nil }
        let calendar = Self.calendar(in: Self.utc)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == year, actual.month == month, actual.day == day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    init?(_ raw: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if raw.count == 4, let year = Self.digits(raw) {
            self.init(year: year)
            return
        }
        guard raw.count >= 10 else { return nil }
        let date = String(raw.prefix(10))
        let pieces = date.split(separator: "-", omittingEmptySubsequences: false)
        let suffix = raw.dropFirst(10)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              suffix.isEmpty || suffix.first == "T" || suffix.first == " ",
              let year = Self.digits(String(pieces[0])), let month = Self.digits(String(pieces[1])),
              let day = Self.digits(String(pieces[2])) else { return nil }
        self.init(year: year, month: month, day: day)
    }

    var storageValue: String {
        guard let month, let day else { return String(format: "%04d", year) }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// No day is invented for a year-only release.
    func calendarDate(in timeZone: TimeZone = .current) -> Date? {
        guard let month, let day else { return nil }
        return Self.calendar(in: timeZone).date(from: DateComponents(year: year, month: month, day: day))
    }

    /// The existing mid-year heuristic is a freshness policy, not release data.
    var estimatedFreshnessDate: Date {
        Self.calendar(in: Self.utc).date(from: DateComponents(year: year, month: month ?? 7, day: day ?? 1))!
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        guard let date = try Self(value.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid calendar release date")
        }
        self = date
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(storageValue)
    }

    private static let utc = TimeZone(secondsFromGMT: 0)!

    private static func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private static func digits(_ value: String) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48 ... 57).contains($0) }) else { return nil }
        return Int(value)
    }
}

nonisolated extension Movie {
    var release: ReleaseDate? {
        get { ReleaseDate(releaseDate) }
        set { releaseDate = newValue?.storageValue }
    }
}

nonisolated extension Series {
    var release: ReleaseDate? {
        get { ReleaseDate(releaseDate) }
        set { releaseDate = newValue?.storageValue }
    }
}

nonisolated extension Episode {
    var release: ReleaseDate? {
        get { ReleaseDate(airDate) }
        set { airDate = newValue?.storageValue }
    }
}
