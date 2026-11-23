//
//  DisabledSet.swift
//  Lume
//
//  A set of switched-off things stored as one comma-separated string: the
//  form `@AppStorage` and the iCloud settings sync carry. Absence means
//  enabled, so the default (empty) turns everything on.
//

import Foundation

/// An element written into a `DisabledSet` by its token.
nonisolated protocol StoredSetElement: Hashable {
    init?(token: String)
    var token: String { get }
}

nonisolated struct DisabledSet<Element: StoredSetElement>: RawRepresentable, Hashable {
    private(set) var elements: Set<Element>

    init(_ elements: Set<Element> = []) {
        self.elements = elements
    }

    /// Unknown tokens (a row since removed, a newer build's area) are dropped.
    init(rawValue: String) {
        elements = Set(rawValue.split(separator: ",").compactMap { Element(token: String($0)) })
    }

    /// Sorted, so the same set always stores the same string.
    var rawValue: String {
        elements.map(\.token).sorted().joined(separator: ",")
    }

    func isEnabled(_ element: Element) -> Bool {
        !elements.contains(element)
    }

    mutating func setEnabled(_ isEnabled: Bool, for element: Element) {
        if isEnabled { elements.remove(element) } else { elements.insert(element) }
    }
}
