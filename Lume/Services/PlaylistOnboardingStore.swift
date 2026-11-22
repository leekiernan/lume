import SwiftData

enum PlaylistOnboardingStore {
    /// A private context keeps failed inserts out of autosave and preserves any
    /// unrelated unsaved changes in the view's context.
    static func insert(_ playlist: Playlist, in container: ModelContainer, save: (ModelContext) throws -> Void = { try $0.save() }) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        context.insert(playlist)
        EPGSourceReconciler.reconcile(playlist, in: context)
        do {
            try save(context)
        } catch {
            context.rollback()
            throw error
        }
    }
}
