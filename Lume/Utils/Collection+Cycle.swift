//
//  Collection+Cycle.swift
//  Lume
//
//  What a tvOS cycle row advances to: the next choice, wrapping to the first.
//

import Foundation

nonisolated extension Collection where Element: Equatable {
    /// The element after `element`, wrapping to the first; the first when
    /// `element` isn't in the collection (a stored value no longer offered).
    func element(after element: Element) -> Element {
        guard let first else { return element }
        guard let index = firstIndex(of: element) else { return first }
        let next = self.index(after: index)
        return next == endIndex ? first : self[next]
    }
}

nonisolated extension CaseIterable where Self: Equatable {
    /// The next case, wrapping to the first.
    func cycledNext() -> Self {
        Self.allCases.element(after: self)
    }
}
