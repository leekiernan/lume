//
//  LenientISO8601.swift
//  Lume
//
//  ISO-8601 instants as services actually send them. Trakt, Simkl, MDBList,
//  ESPN and Lume's own metadata service all use internet date-time, some with
//  fractional seconds (`2014-10-11T17:00:54.000Z`) and some without
//  (`2014-10-11T17:00:54Z`). A formatter set up for one form rejects the
//  other, so both are tried — through one cached pair, rather than a copy per
//  client or a new formatter per value.
//

import Foundation

nonisolated enum LenientISO8601 {
    static func date(from string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return whole.date(from: string) ?? fractional.date(from: string)
    }

    /// `ISO8601DateFormatter` is thread-safe; these are shared across actors.
    private static let whole = ISO8601DateFormatter()

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
