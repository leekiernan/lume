//
//  MainThreadStallWatch.swift
//  Lume
//
//  Logs when the main thread stops answering, and for how long. A blocked
//  main thread can't log its own block: the player's tick, the overlay and
//  every remote press wait behind it. So this asks from a background queue
//  and logs from there.
//
//  Each half second it sends the main queue an empty block, unless one is
//  still waiting. A block left unanswered for two seconds is a stall, logged
//  once, and its answer logs the stall's full length. Nothing is logged while
//  the main thread keeps up.
//

import Foundation
import OSLog
import QuartzCore

final nonisolated class MainThreadStallWatch: @unchecked Sendable {
    static let shared = MainThreadStallWatch()

    /// How long the main thread may go unanswered before it counts as stalled.
    static let threshold: TimeInterval = 2
    private static let interval: DispatchTimeInterval = .milliseconds(500)

    /// Everything below is touched on `queue` only.
    private let queue = DispatchQueue(label: "com.leekiernan.lume.main-stall-watch", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var pingSentAt: TimeInterval?
    private var reported = false

    private init() {}

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            self.timer = timer
        }
    }

    private func check() {
        let now = CACurrentMediaTime()
        guard let sentAt = pingSentAt else {
            pingSentAt = now
            DispatchQueue.main.async { [self] in
                queue.async { self.answered() }
            }
            return
        }
        let waited = now - sentAt
        guard !reported, waited >= Self.threshold else { return }
        reported = true
        Logger.performance.error("main thread unresponsive for \(waited, format: .fixed(precision: 1), privacy: .public)s")
    }

    private func answered() {
        guard let sentAt = pingSentAt else { return }
        pingSentAt = nil
        guard reported else { return }
        reported = false
        let waited = CACurrentMediaTime() - sentAt
        Logger.performance.error("main thread responsive again after \(waited, format: .fixed(precision: 1), privacy: .public)s")
    }
}
