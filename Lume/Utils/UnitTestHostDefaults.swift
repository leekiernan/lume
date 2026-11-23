//
//  UnitTestHostDefaults.swift
//  Lume
//
//  `LumeTests` runs inside the app, so `UserDefaults.standard` there is the
//  machine's own Lume settings. Code under test keeps per-playlist and
//  per-profile bookkeeping there (sync coverage, digests, scoped layout keys),
//  and every test playlist or profile has a fresh id, so each run used to
//  leave its keys behind — 26,000 of them on one development Mac, past the
//  4 MB UserDefaults limit.
//
//  The unit-test host notes which keys exist when it starts and removes any
//  new ones as it exits. Only additions are undone: a value a test changed on
//  an existing key is `TestProfileBaseline`'s to restore, and a key the real
//  app wrote between runs is never touched. A run killed before it exits
//  leaves its keys to `OrphanedDeviceStateSweep` on the next normal launch.
//

import Foundation
import OSLog

nonisolated enum UnitTestHostDefaults {
    /// Written once, on the main thread during launch, and read only at exit.
    private nonisolated(unsafe) static var keysAtLaunch: Set<String> = []

    static func removeAddedKeysOnExit() {
        keysAtLaunch = currentKeys()
        atexit { UnitTestHostDefaults.removeAddedKeys() }
    }

    private static func removeAddedKeys() {
        let defaults = UserDefaults.standard
        let added = currentKeys().subtracting(keysAtLaunch)
        for key in added {
            defaults.removeObject(forKey: key)
        }
        Logger.app.notice("Unit-test host: removed \(added.count, privacy: .public) settings the run added")
        // The process is about to end; flush before it does.
        defaults.synchronize()
    }

    private static func currentKeys() -> Set<String> {
        guard let domain = Bundle.main.bundleIdentifier else { return [] }
        return Set(UserDefaults.standard.persistentDomain(forName: domain)?.keys.map(\.self) ?? [])
    }
}
