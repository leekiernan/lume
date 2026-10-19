//
//  ProfilingMarks.swift
//  Lume
//
//  TEMPORARY: Points of Interest intervals for verifying the artwork
//  freshness fixes on device. The stock Time Profiler template records this
//  category, unlike `Perf`'s `Performance` one, so a capture needs no custom
//  instrument settings. Names carry no titles, ids, accounts or URLs.
//  Remove once a device capture has verified the fixes.
//

import OSLog

nonisolated enum ProfilingMarks {
    private static let signposter = OSSignposter(subsystem: Perf.subsystem, category: .pointsOfInterest)

    static func measure<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let interval = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, interval) }
        return try body()
    }
}
