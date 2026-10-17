import Foundation

extension WidgetSnapshotExporter {
    /// A failed visibility read is not an unrestricted viewer. Returning nil
    /// makes the exporter publish no content rather than disclose hidden rows.
    nonisolated static func visibility(isChildProfile: Bool, read: () throws -> [Category]) -> ContentRestriction? {
        guard let categories = try? read() else { return nil }
        return ContentRestriction(
            isActive: isChildProfile,
            restrictedCategoryIDs: Set(categories.filter(\.isRestricted).map(\.id)),
            hiddenCategoryIDs: Set(categories.filter(\.isHidden).map(\.id))
        )
    }
}
