//
//  PlayerOrientationLock.swift
//  Lume
//
//  Turns an iPhone to landscape while the player is open and back to portrait
//  when it closes, behind `PlayerSettings.Playback.rotateToLandscape`.
//

import SwiftUI

#if os(iOS)
    import OSLog
    import UIKit

    /// The orientations the app allows right now, answered to UIKit through
    /// `LumeAppDelegate`'s `supportedInterfaceOrientationsFor`. Overriding that
    /// callback replaces the Info.plist list, so the unlocked mask has to repeat
    /// it per idiom.
    enum PlayerOrientationLock {
        /// Players currently holding the lock. A set rather than a flag so a
        /// repeated `onAppear` stays idempotent and the lock only lifts once the
        /// last holder is gone.
        private static var holders: Set<String> = []

        static var supportedOrientations: UIInterfaceOrientationMask {
            orientations(locked: !holders.isEmpty, idiom: UIDevice.current.userInterfaceIdiom)
        }

        static func orientations(locked: Bool, idiom: UIUserInterfaceIdiom) -> UIInterfaceOrientationMask {
            if locked { return .landscape }
            return idiom == .phone ? .allButUpsideDown : .all
        }

        /// Whether a player opening now should lock. iPhone only: iPadOS ignores
        /// geometry requests whenever the app runs in a resizable window.
        static var appliesToNewPlayer: Bool {
            UIDevice.current.userInterfaceIdiom == .phone && PlayerSettings.Playback.rotateToLandscape
        }

        static func acquire(_ holder: String) {
            guard holders.insert(holder).inserted, holders.count == 1 else { return }
            apply(requesting: .landscape)
        }

        static func release(_ holder: String) {
            guard holders.remove(holder) != nil, holders.isEmpty else { return }
            apply(requesting: .portrait)
        }

        /// How long the system takes to turn the interface a quarter turn on
        /// iPhone. UIKit exposes no completion for a geometry request.
        private static let rotationDuration: Duration = .milliseconds(400)

        /// Lifts the lock ahead of a dismissal and calls `completion` once the
        /// phone is back in portrait. Releasing from `onDisappear` alone would
        /// slide the cover away over an app still in landscape and only then
        /// turn it; rotating the player first means the app is never seen
        /// sideways. Calls straight through when nothing holds the lock, and
        /// skips the wait in the background, where nothing animates.
        static func releaseAll(then completion: @escaping @MainActor () -> Void) {
            guard !holders.isEmpty else { return completion() }
            holders.removeAll()
            apply(requesting: .portrait)
            guard UIApplication.shared.applicationState == .active else { return completion() }
            Task {
                try? await Task.sleep(for: rotationDuration)
                completion()
            }
        }

        private static func apply(requesting orientations: UIInterfaceOrientationMask) {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                // Every controller in the presentation chain caches its
                // supported mask; the player's cover is the topmost one.
                var controller = scene.keyWindow?.rootViewController
                while let current = controller {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    controller = current.presentedViewController
                }
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
                    Logger.player.error("Orientation request failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
#endif

extension DismissAction {
    /// Closes a full-screen player. On an iPhone the lock holds in landscape,
    /// the player turns back to portrait first and the cover goes once it has —
    /// see `PlayerOrientationLock.releaseAll(then:)`.
    func dismissPlayer() {
        #if os(iOS)
            PlayerOrientationLock.releaseAll { self() }
        #else
            self()
        #endif
    }
}

extension View {
    /// Holds `PlayerOrientationLock` for as long as this player is on screen,
    /// when the setting is on as the player opens. A no-op off iOS.
    func playerOrientationLock() -> some View {
        #if os(iOS)
            modifier(PlayerOrientationLockModifier())
        #else
            self
        #endif
    }
}

#if os(iOS)
    private struct PlayerOrientationLockModifier: ViewModifier {
        @State private var holder = "player-\(UUID().uuidString)"

        func body(content: Content) -> some View {
            content
                .onAppear {
                    guard PlayerOrientationLock.appliesToNewPlayer else { return }
                    PlayerOrientationLock.acquire(holder)
                }
                .onDisappear { PlayerOrientationLock.release(holder) }
        }
    }
#endif
