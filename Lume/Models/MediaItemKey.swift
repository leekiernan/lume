//
//  MediaItemKey.swift
//  Lume
//
//  A content item's kind-qualified identity, `kind-catalogID`: the id of a
//  rail item (`HomeMediaItem`), a hero, a search result, something playing
//  (`PlayableMedia`) and a Top Shelf item, and the form the Top Shelf records
//  rows in. Catalog ids are unique only within a kind, so the kind is part of
//  the key. Building and parsing it live here, so the format has one owner.
//

import Foundation

nonisolated struct MediaItemKey: Hashable, CustomStringConvertible {
    nonisolated enum Kind: String {
        case movie
        case series
        case episode
        case live
    }

    let kind: Kind
    let id: String

    init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }

    static func movie(_ id: String) -> Self {
        Self(kind: .movie, id: id)
    }

    static func series(_ id: String) -> Self {
        Self(kind: .series, id: id)
    }

    static func episode(_ id: String) -> Self {
        Self(kind: .episode, id: id)
    }

    static func live(_ id: String) -> Self {
        Self(kind: .live, id: id)
    }

    /// Splits at the first `-`: catalog ids contain dashes, kinds don't.
    init?(_ string: String) {
        guard let separator = string.firstIndex(of: "-"),
              let kind = Kind(rawValue: String(string[..<separator])) else { return nil }
        self.init(kind: kind, id: String(string[string.index(after: separator)...]))
    }

    var description: String {
        "\(kind.rawValue)-\(id)"
    }
}
