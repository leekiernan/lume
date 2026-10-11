import Foundation
import Observation

/// One navigation-menu owner used by every area. Remembering a row restores
/// Browse's position; it does not imply a category filter is still active.
@MainActor @Observable
final class BrowseSidebarState {
    var isPresented = false {
        didSet {
            guard isPresented != oldValue else { return }
            cancelFocusReturn()
            if isPresented { opener = contentFocus }
        }
    }

    var rememberedRowID: String?

    /// Snapshot the opener before the panel steals native focus. Targets belong
    /// to controls, not titles/channel IDs: the same title can occur in two rails.
    private struct FocusTarget {
        let id: UUID
        let restore: (@escaping () -> Bool) async -> Void
    }

    @ObservationIgnored private var contentFocus: FocusTarget?
    @ObservationIgnored private var opener: FocusTarget?
    @ObservationIgnored private var returningTo: UUID?
    @ObservationIgnored private var returnRevision = 0
    @ObservationIgnored private var returnTask: Task<Void, Never>?

    func rememberContentFocus(id: UUID, restore: @escaping (@escaping () -> Bool) async -> Void) {
        // Incidental focus while the panel lands must not replace its opener.
        guard !isPresented else { return }
        contentFocus = FocusTarget(id: id, restore: restore)
    }

    func releaseContentFocus(id: UUID) {
        if !isPresented, contentFocus?.id == id { contentFocus = nil }
    }

    func removeContentFocus(id: UUID) {
        if contentFocus?.id == id { contentFocus = nil }
        if opener?.id == id { opener = nil }
        if returningTo == id { cancelFocusReturn() }
    }

    /// A departed page, changed playlist/profile or different presentation
    /// must not reclaim focus using the previous content's bindings.
    func invalidateContentFocus() {
        contentFocus = nil
        opener = nil
        cancelFocusReturn()
    }

    /// Right/Menu means cancel, not navigation. Let the control's own SwiftUI
    /// binding release, settle and reclaim focus after the overlay unmounts.
    @discardableResult
    func dismissToContent() -> Task<Void, Never>? {
        guard isPresented else { return nil }
        let target = opener
        opener = nil
        isPresented = false
        guard let target else { return nil }
        returningTo = target.id
        let revision = returnRevision
        let task = Task { [weak self] in
            await target.restore { [weak self] in
                guard let self else { return false }
                return !Task.isCancelled && !isPresented && returnRevision == revision && returningTo == target.id
            }
            guard let self, returnRevision == revision else { return }
            returningTo = nil
            returnTask = nil
        }
        returnTask = task
        return task
    }

    private func cancelFocusReturn() {
        returnTask?.cancel()
        returnTask = nil
        returningTo = nil
        returnRevision += 1
    }

    /// Close before navigating so a pushed page or presented sheet cannot
    /// leave Browse over the new destination. Callers only supply the action.
    func activate(rowID: String, navigate: () -> Void) {
        rememberedRowID = rowID
        opener = nil
        isPresented = false
        navigate()
    }
}
