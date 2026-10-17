import Foundation
import SwiftData

/// Keyset paging for catalogue maintenance. Each page releases its context and
/// relationships after saving; saving batches of one huge fetch did not do that.
/// The concrete descriptor must use `id > cursor` in lexical order.
nonisolated enum CatalogMaintenance {
    static func mutate<Row: CatalogImportRow>(
        container: ModelContainer,
        pageSize: Int = 1000,
        scope: ProfileScope? = nil,
        page: (String) -> FetchDescriptor<Row>,
        mutate: ([Row], ModelContext) throws -> Void
    ) throws {
        precondition(pageSize > 0)
        var cursor = ""
        while true {
            try Task.checkCancellation()
            func perform() throws -> Int {
                try autoreleasepool {
                    let context = ModelContext(container)
                    context.autosaveEnabled = false
                    var descriptor = page(cursor)
                    descriptor.fetchLimit = pageSize
                    let rows = try context.fetch(descriptor)
                    guard let last = rows.last else { return 0 }
                    cursor = last.id
                    try mutate(rows, context)
                    try Task.checkCancellation()
                    try context.save()
                    return rows.count
                }
            }
            let count: Int
            if let scope {
                guard let saved = try ProfileProjectionGate.shared.withCurrent(scope, operation: perform) else { throw CancellationError() }
                count = saved
            } else {
                count = try perform()
            }
            if count < pageSize { return }
        }
    }
}
