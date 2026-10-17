import Foundation
@testable import Lume
import Testing

/// `addObserver(forName:object:queue: .main)` blocks a background poster until
/// the main thread runs the block. A full test run measured dozens of threads
/// parked there, and a poster holding a lock could deadlock against main.
@MainActor
@Suite(.globalState)
struct MainActorObserverTests {
    private let name = Notification.Name("MainActorObserverTests.\(UUID().uuidString)")

    @Test func `a background post does not wait for a busy main thread`() {
        var delivered = 0
        let observer = NotificationCenter.default.addMainActorObserver(forName: name, object: nil) { _ in delivered += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let posted = DispatchSemaphore(value: 0)
        let name = name
        DispatchQueue.global().async {
            NotificationCenter.default.post(name: name, object: nil)
            posted.signal()
        }
        // The main thread stays blocked here: with a `.main` queue observer
        // the post could not return and this would time out.
        #expect(posted.wait(timeout: .now() + 10) == .success)
        #expect(delivered == 0)
    }

    /// The platform behaviour the helper exists for: a `.main` queue observer
    /// holds a background poster until the main thread runs its block.
    @Test func `control: a main queue observer makes a background poster wait`() {
        let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in }
        defer { NotificationCenter.default.removeObserver(observer) }
        let posted = DispatchSemaphore(value: 0)
        let name = name
        DispatchQueue.global().async {
            NotificationCenter.default.post(name: name, object: nil)
            posted.signal()
        }
        // This test is itself a main-queue item, so the block (and with it the
        // post) completes only once the test has returned.
        #expect(posted.wait(timeout: .now() + 0.5) == .timedOut)
    }

    @Test func `a background post is delivered on the main actor afterwards`() async {
        let (deliveries, deliver) = AsyncStream<Bool>.makeStream()
        let observer = NotificationCenter.default.addMainActorObserver(forName: name, object: nil) { _ in
            deliver.yield(Thread.isMainThread)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let name = name
        DispatchQueue.global().async { NotificationCenter.default.post(name: name, object: nil) }
        var iterator = deliveries.makeAsyncIterator()
        #expect(await iterator.next() == true)
    }

    @Test func `a main-thread post is delivered before it returns`() {
        var delivered = false
        let observer = NotificationCenter.default.addMainActorObserver(forName: name, object: nil) { _ in delivered = true }
        defer { NotificationCenter.default.removeObserver(observer) }
        NotificationCenter.default.post(name: name, object: nil)
        #expect(delivered)
    }

    /// Setting the profile writes `UserDefaults`, whose observers run inline
    /// on the main thread. One that reads the scope used to re-enter the
    /// store's lock, still held around the write.
    @Test func `an observer of the profile write may read the scope`() {
        let saved = ActiveProfileStore.current
        defer { ActiveProfileStore.current = saved }
        let target = UUID()
        var seen: UUID?
        let observer = NotificationCenter.default.addMainActorObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard
        ) { _ in
            if ActiveProfileStore.current == target { seen = ProfileScope.current.profileID }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        ActiveProfileStore.current = target
        #expect(seen == target)
        #expect(ProfileScope.current.profileID == target)
    }
}
