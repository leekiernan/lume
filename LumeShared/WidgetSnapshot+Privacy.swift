import Foundation

nonisolated extension WidgetSnapshot {
    /// Defence in depth for every snapshot writer (and pre-existing snapshots).
    /// Authenticated images must already be app-rendered files before exporting.
    var withoutArtworkCredentials: Self {
        var copy = self
        for section in copy.sections.indices {
            for item in copy.sections[section].items.indices {
                copy.sections[section].items[item].imageURL = Self.safe(copy.sections[section].items[item].imageURL)
                copy.sections[section].items[item].backdropURL = Self.safe(copy.sections[section].items[item].backdropURL)
                copy.sections[section].items[item].logoURL = Self.safe(copy.sections[section].items[item].logoURL)
                copy.sections[section].items[item].artURL = Self.safe(copy.sections[section].items[item].artURL)
            }
        }
        return copy
    }

    private static func safe(_ url: URL?) -> URL? {
        guard let url else { return nil }
        return ArtworkRequest.carriesCredentials(url) ? nil : url
    }
}
