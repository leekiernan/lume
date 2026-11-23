//
//  URLQueryEncoding.swift
//  Lume
//
//  Percent-encoding for a value placed in a query string or form body by
//  hand. `.urlQueryAllowed` keeps `&`, `=`, `+` and `?` literal, which cuts a
//  value short or splits it; `CharacterSet.alphanumerics` keeps non-ASCII
//  letters. Clients each removed a different handful of characters, so the
//  copies disagreed. This keeps only RFC 3986's unreserved characters.
//

import Foundation

nonisolated extension String {
    /// Percent-encoded for use as one query-item or form value (or name).
    var urlQueryValueEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlUnreserved) ?? self
    }
}

nonisolated extension CharacterSet {
    /// RFC 3986 unreserved: ASCII letters and digits, `-`, `.`, `_` and `~`.
    static let urlUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
