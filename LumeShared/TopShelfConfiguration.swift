//
//  TopShelfConfiguration.swift
//  LumeShared
//
//  How the tvOS Top Shelf presents the snapshot: the layout and how many items
//  each section holds. Which sections appear, and in what order, is the
//  snapshot's `sections` itself. The app owns the user's choice
//  (`TopShelfSettings`) and writes it into the snapshot; the Top Shelf
//  extension only reads it.
//

import Foundation

nonisolated struct TopShelfConfiguration: Codable, Equatable {
    /// `sectioned` is rows of posters under section titles; `carousel` is the
    /// full-width, auto-advancing backdrop carousel.
    nonisolated enum Style: String, Codable, CaseIterable {
        case sectioned
        case carousel
    }

    var style: Style
    var itemsPerSection: Int

    /// The choices offered for `itemsPerSection`.
    static let itemCountChoices = [5, 10, 20]

    /// The most items the snapshot carries per section — the largest choice.
    static var maxItemsPerSection: Int {
        itemCountChoices.max() ?? 20
    }

    static let `default` = TopShelfConfiguration(style: .sectioned, itemsPerSection: 10)
}
