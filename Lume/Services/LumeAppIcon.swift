import Foundation
import Observation
import OSLog
#if os(iOS) || os(tvOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

/// One process owns icon updates, including when only the Mac's Settings
/// window remains. Windows start it idempotently; they do not own its work.
/// The system still owns icon-change alerts, Finder's bundled icon and the
/// primary icon tvOS displays in its app switcher.
@MainActor
final class LumeAppIcon {
    typealias Apply = (LumeIconChoice, @escaping @MainActor (Bool) -> Void) -> Void

    static let shared = LumeAppIcon(isActive: { LumeAppIcon.appIsActive }, apply: LumeAppIcon.apply)

    private let isActive: () -> Bool
    private let apply: Apply
    private var machine = LumeAppIconMachine()
    private var store: LumeThemeStore?
    private var readAccess: (@MainActor () -> LumeThemeAccess)?
    private var activationObserver: NSObjectProtocol?

    init(isActive: @escaping () -> Bool, apply: @escaping Apply) {
        self.isActive = isActive
        self.apply = apply
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    func start(store: LumeThemeStore? = nil, access: @escaping @MainActor () -> LumeThemeAccess = {
        let premium = PremiumManager.shared
        return LumeThemeAccess(resolved: premium.hasResolvedEntitlements, isPremium: premium.isPremium)
    }) {
        guard self.store == nil else { return }
        let store = store ?? LumeThemeStore.shared
        self.store = store
        readAccess = access
        store.selectionDidCommit = { [weak self] choice in self?.request(choice) }
        observeAccess()
        request(store.iconChoice)
        #if os(iOS) || os(tvOS) || os(macOS)
            #if os(macOS)
                let notification = NSApplication.didBecomeActiveNotification
            #else
                let notification = UIApplication.didBecomeActiveNotification
            #endif
            activationObserver = NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.resume() }
            }
        #endif
    }

    /// Re-observe only entitlements: preference mutations below must not arm
    /// another entitlement observer or turn a reset into a feedback loop.
    private func observeAccess() {
        guard let readAccess else { return }
        let access = withObservationTracking {
            readAccess()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeAccess()
            }
        }
        store?.updateAccess(access)
    }

    func request(_ choice: LumeIconChoice) {
        machine.request(choice)
        resume()
    }

    /// Foreground entry or an explicit selection retries a failed request.
    /// Completion alone never retries the same failed choice indefinitely.
    func resume() {
        guard let choice = machine.begin(isActive: isActive()) else { return }
        apply(choice) { [weak self] succeeded in
            guard let self else { return }
            if machine.finish(succeeded: succeeded) { resume() }
        }
    }

    private static var appIsActive: Bool {
        #if os(iOS) || os(tvOS)
            UIApplication.shared.applicationState == .active
        #elseif os(macOS)
            NSApplication.shared.isActive
        #else
            true
        #endif
    }

    private static func apply(_ choice: LumeIconChoice, completion: @escaping @MainActor (Bool) -> Void) {
        #if os(iOS) || os(tvOS)
            let app = UIApplication.shared
            let name = choice.iconName
            guard app.supportsAlternateIcons, app.alternateIconName != name else { completion(true); return }
            app.setAlternateIconName(name) { error in
                Task { @MainActor in
                    if let error {
                        Logger.app.error("App icon: couldn't switch to \(name ?? "primary", privacy: .public): \(LogRedaction.describe(error), privacy: .public)")
                    }
                    completion(error == nil)
                }
            }
        #elseif os(macOS)
            if choice.iconName == nil {
                NSApplication.shared.applicationIconImage = nil
            } else {
                guard let image = MacDockIcon.image(for: choice) else {
                    Logger.app.error("App icon: couldn't render the Dock icon")
                    completion(false)
                    return
                }
                NSApplication.shared.applicationIconImage = image
            }
            completion(true)
        #else
            // Native visionOS has no alternate-icon support.
            completion(true)
        #endif
    }
}

/// Latest selection wins, with at most one platform request in flight. A
/// failed request retains the last applied choice and waits for an explicit
/// retry, unless a different choice has already superseded it.
struct LumeAppIconMachine {
    enum State: Equatable {
        case idle(applied: LumeIconChoice?)
        case updating(LumeIconChoice, applied: LumeIconChoice?)
    }

    private(set) var state = State.idle(applied: nil)
    private var desired: LumeIconChoice?

    mutating func request(_ choice: LumeIconChoice) {
        desired = choice
    }

    mutating func begin(isActive: Bool) -> LumeIconChoice? {
        guard isActive, case let .idle(applied) = state, let desired, desired != applied else { return nil }
        state = .updating(desired, applied: applied)
        return desired
    }

    /// Whether completion should immediately drain a superseding selection.
    mutating func finish(succeeded: Bool) -> Bool {
        guard case let .updating(request, applied) = state else { return false }
        state = .idle(applied: succeeded ? request : applied)
        return desired != request
    }
}
