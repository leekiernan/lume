import Foundation

nonisolated extension NotificationCenter {
    /// Observes `name` on the main actor without making a poster wait for it.
    ///
    /// `addObserver(forName:object:queue: .main)` delivers a post from any
    /// other thread by enqueueing the block on the main queue *and blocking the
    /// posting thread until it has run*. For notifications posted from
    /// background work — every `ModelContext.didSave`, `UserDefaults` write,
    /// store remote change or audio route change — that parks the poster until
    /// the main thread is free. Measured in a full test run, dozens of pool
    /// threads sat in `-[NSOperation waitUntilFinished]` at once. A poster that
    /// holds a lock while posting can deadlock against a main thread that wants
    /// the same lock.
    ///
    /// Here a post from the main thread still runs the handler inline, as
    /// before, so code that relies on synchronous delivery while it writes
    /// (`ProfilePreferencesSynchronizer.isApplyingPreferences`) is unchanged.
    /// A post from elsewhere is handed to the main queue, in posting order,
    /// and the poster carries on.
    func addMainActorObserver(
        forName name: Notification.Name?,
        object: Any?,
        using handler: @escaping @MainActor (Notification) -> Void
    ) -> NSObjectProtocol {
        addObserver(forName: name, object: object, queue: nil) { notification in
            if Thread.isMainThread {
                MainActor.assumeIsolated { handler(notification) }
            } else {
                // Delivered once, to this handler alone, on the main queue.
                nonisolated(unsafe) let notification = notification
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { handler(notification) }
                }
            }
        }
    }
}
