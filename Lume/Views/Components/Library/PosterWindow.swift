//
//  PosterWindow.swift
//  Lume
//
//  The posters a paged grid has shown so far, shared by every grid loader
//  (collections, categories, genres) so they agree on what a page adds. A row
//  already shown, or another copy of a title already shown (`duplicateKey`,
//  the TMDB identity — see `DuplicateTitles`), is left out: providers list
//  one film once per quality, language or mirror.
//
//  Loaders keep their own fetching (SQL pages, a background genre scan, a
//  portal import); this only decides which rows of a page are new. A page that
//  adds nothing must not end the walk — the grid asks for the next page when
//  its last poster appears, and no new poster means no new ask — so loaders
//  read `accept`'s count and fetch on.
//

struct PosterWindow<Item: Hashable> {
    private(set) var items: [Item] = []
    private var shown: Set<Item> = []
    private var titles: Set<AnyHashable> = []
    private let duplicateKey: (Item) -> AnyHashable?

    /// - Parameter duplicateKey: two rows with the same key are one title;
    ///   nil keeps every row (unmatched titles, or a grid that doesn't group).
    init(duplicateKey: @escaping (Item) -> AnyHashable? = { _ in nil }) {
        self.duplicateKey = duplicateKey
    }

    var isEmpty: Bool {
        items.isEmpty
    }

    var count: Int {
        items.count
    }

    /// Adds the page's new titles, in order. Returns how many were added.
    @discardableResult
    mutating func accept(_ rows: [Item]) -> Int {
        let before = items.count
        for row in rows where shown.insert(row).inserted {
            if let key = duplicateKey(row), !titles.insert(key).inserted { continue }
            items.append(row)
        }
        return items.count - before
    }

    /// Starts again from `rows` — a revalidated window.
    mutating func replace(with rows: [Item]) {
        removeAll()
        accept(rows)
    }

    mutating func removeAll() {
        items = []
        shown = []
        titles = []
    }
}

extension DuplicableTitle {
    /// The key a grid groups copies of one title by: the namespaced TMDB id,
    /// nil until the row is matched.
    var duplicateKey: AnyHashable? {
        tmdbId.map { "\(Self.duplicateNamespace)-\($0)" }
    }
}
