//
//  Eventually.swift
//  LumeTests
//
//  Waiting for another task to reach a state. The limit is a backstop, so a
//  regression fails rather than hangs the suite; it is not a performance
//  bound. Under a full parallel run, scheduling lags by seconds, and a budget
//  counted in yields or a few seconds failed tests that were only queued.
//  When a test must show something did *not* happen, give it its own short,
//  explicit wait instead.
//

import Foundation

/// Polls `condition` until it holds, or `limit` passes. Returns whether it held.
func eventually(within limit: Duration = .seconds(30), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}
