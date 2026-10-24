import Foundation
@testable import Lume
import Observation
import Testing

@MainActor
struct LumeAppIconTests {
    private let primary = LumeIconChoice(theme: .pink, logo: .afterglow)
    private let ice = LumeIconChoice(theme: .ice, logo: .afterglow)
    private let green = LumeIconChoice(theme: .green, logo: .floodlight)

    @MainActor
    private final class Platform {
        var active = true
        var requests: [LumeIconChoice] = []
        var completions: [@MainActor (Bool) -> Void] = []
        let updates = AsyncStream.makeStream(of: LumeIconChoice.self)
        lazy var owner = LumeAppIcon(isActive: { [unowned self] in active }, apply: { [unowned self] choice, completion in
            requests.append(choice)
            updates.continuation.yield(choice)
            completions.append(completion)
        })

        func finish(_ succeeded: Bool) {
            completions.removeFirst()(succeeded)
        }
    }

    @Test(arguments: [false, true])
    func `rapid selections coalesce behind one request even when it fails`(succeeded: Bool) {
        let platform = Platform()
        platform.owner.request(ice)
        platform.owner.request(green)
        platform.owner.request(primary)
        #expect(platform.requests == [ice])
        #expect(platform.completions.count == 1)
        platform.finish(succeeded)
        #expect(platform.requests == [ice, primary])
        platform.finish(true)
        #expect(platform.completions.isEmpty)
    }

    @Test(arguments: [false, true])
    func `returning to the previous icon waits for the in flight result`(succeeded: Bool) {
        let platform = Platform()
        platform.owner.request(primary)
        platform.finish(true)
        platform.owner.request(ice)
        platform.owner.request(primary)
        #expect(platform.requests == [primary, ice])
        platform.finish(succeeded)
        #expect(platform.requests == (succeeded ? [primary, ice, primary] : [primary, ice]))
    }

    @Test func `failure stops until the same choice is explicitly retried`() {
        let platform = Platform()
        platform.owner.request(ice)
        platform.finish(false)
        #expect(platform.requests == [ice])
        #expect(platform.completions.isEmpty)
        platform.owner.request(ice)
        #expect(platform.requests == [ice, ice])
        platform.finish(true)
        platform.owner.request(ice)
        #expect(platform.requests.count == 2)
    }

    @Test func `foreground entry retries a failure but never repeats a successful render`() {
        let platform = Platform()
        platform.owner.request(green)
        platform.finish(false)
        platform.active = false
        platform.owner.resume()
        #expect(platform.requests.count == 1)
        platform.active = true
        platform.owner.resume()
        #expect(platform.requests == [green, green])
        platform.finish(true)
        platform.owner.resume()
        platform.owner.request(green)
        #expect(platform.requests.count == 2)
    }

    @Test func `background selections wait and apply only the latest choice`() {
        let platform = Platform()
        platform.active = false
        platform.owner.request(ice)
        platform.owner.request(green)
        #expect(platform.requests.isEmpty)
        platform.active = true
        platform.owner.resume()
        #expect(platform.requests == [green])
    }

    @Test func `a completion cannot start the next update after backgrounding`() {
        let platform = Platform()
        platform.owner.request(ice)
        platform.owner.request(green)
        platform.active = false
        platform.finish(true)
        #expect(platform.requests == [ice])
        platform.active = true
        platform.owner.resume()
        #expect(platform.requests == [ice, green])
    }

    @Test func `multiple windows requesting one choice share its application`() {
        let platform = Platform()
        platform.owner.request(green)
        platform.owner.request(green)
        platform.owner.resume()
        #expect(platform.requests == [green])
        platform.finish(true)
        platform.owner.request(green)
        #expect(platform.requests == [green])
    }

    @Test(.timeLimit(.minutes(1)))
    func `one start observes Pro loss and recovery without a window or StoreKit`() async throws {
        let suite = "LumeAppIconTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LumeThemeStore(defaults: defaults)
        store.select(.green)
        store.select(LumeLogo.floodlight)
        let platform = Platform()
        let access = IconTestAccess()
        var reads = 0
        var didReadAccess: (() -> Void)?
        let readAccess: @MainActor () -> LumeThemeAccess = {
            reads += 1
            let value = access.value
            didReadAccess?()
            return value
        }
        platform.owner.start(store: store, access: readAccess)
        platform.owner.start(store: store, access: readAccess)
        #expect(reads == 1)
        var updates = platform.updates.stream.makeAsyncIterator()
        #expect(await updates.next() == green)
        platform.finish(true)

        access.value = .free
        #expect(await updates.next() == primary)
        #expect(store.iconChoice == primary)
        platform.finish(true)
        store.select(.ice)
        #expect(platform.requests == [green, primary])

        // Recovery re-arms the same observation and permits selection again.
        await withCheckedContinuation { continuation in
            didReadAccess = {
                didReadAccess = nil
                continuation.resume()
            }
            access.value = .premium
        }
        store.select(.ice)
        #expect(await updates.next() == ice)
    }
}

@MainActor
@Observable
private final class IconTestAccess {
    var value = LumeThemeAccess.unresolved
}
