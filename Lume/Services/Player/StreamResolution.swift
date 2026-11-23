//
//  StreamResolution.swift
//  Lume
//
//  Where resolving a Stalker placeholder into a playable URL stands, for the
//  stream on screen. Each attempt gets a ticket; a result is applied only
//  while its ticket is still current, so a resolve that finishes (or fails on
//  being cancelled) after the viewer moved to another channel or pressed Try
//  Again can't put its URL or its failure on the stream that replaced it.
//

import Foundation

nonisolated struct StreamResolution: Equatable {
    struct Ticket: Equatable {
        fileprivate let serial: Int
        let mediaID: String
    }

    enum State: Equatable {
        case idle
        case resolving(Ticket)
        case resolved(PlayableMedia)
        case failed(mediaID: String)
    }

    private(set) var state: State = .idle
    private var serial = 0

    /// Starts an attempt for `mediaID`, replacing any in flight.
    mutating func begin(_ mediaID: String) -> Ticket {
        serial += 1
        let ticket = Ticket(serial: serial, mediaID: mediaID)
        state = .resolving(ticket)
        return ticket
    }

    /// True when `ticket` was current and the result is now the stream's.
    @discardableResult
    mutating func finish(_ ticket: Ticket, with media: PlayableMedia) -> Bool {
        guard state == .resolving(ticket) else { return false }
        state = .resolved(media)
        return true
    }

    /// True when `ticket` was current and its failure now shows.
    @discardableResult
    mutating func fail(_ ticket: Ticket) -> Bool {
        guard state == .resolving(ticket) else { return false }
        state = .failed(mediaID: ticket.mediaID)
        return true
    }

    /// Forgets whatever was resolved: the stream needs no resolving.
    mutating func reset() {
        state = .idle
    }

    /// The resolved stream for `mediaID`, if that's the one resolved.
    func media(for mediaID: String) -> PlayableMedia? {
        if case let .resolved(media) = state, media.id == mediaID { return media }
        return nil
    }

    func hasFailed(_ mediaID: String) -> Bool {
        state == .failed(mediaID: mediaID)
    }

    /// Moves the resolved stream's start to `position` (an engine taking over
    /// mid-stream), keeping the short-lived URL.
    mutating func rebase(_ mediaID: String, at position: TimeInterval) {
        if let media = media(for: mediaID) { state = .resolved(media.resuming(at: position)) }
    }
}
