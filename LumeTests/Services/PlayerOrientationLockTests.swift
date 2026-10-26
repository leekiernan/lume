#if os(iOS)
    import Foundation
    @testable import Lume
    import Testing
    import UIKit

    struct PlayerOrientationLockTests {
        @Test func `locked player allows landscape only`() {
            #expect(PlayerOrientationLock.orientations(locked: true, idiom: .phone) == .landscape)
            #expect(PlayerOrientationLock.orientations(locked: true, idiom: .pad) == .landscape)
        }

        /// The app delegate's mask replaces Info.plist's list, so unlocked it
        /// must allow exactly what the plist declares, or browsing loses an
        /// orientation it has always had.
        @Test(arguments: [
            (UIUserInterfaceIdiom.phone, "UISupportedInterfaceOrientations~iphone"),
            (UIUserInterfaceIdiom.pad, "UISupportedInterfaceOrientations~ipad")
        ])
        func `unlocked mask matches Info plist`(idiom: UIUserInterfaceIdiom, plistKey: String) throws {
            // The raw file, not `infoDictionary`: the bundle collapses `~iphone`
            // / `~ipad` keys to the running device's variant.
            let url = try #require(Bundle.main.url(forResource: "Info", withExtension: "plist"))
            let plist = try #require(NSDictionary(contentsOf: url))
            let declared = try #require(plist[plistKey] as? [String])
            let masks: [String: UIInterfaceOrientationMask] = [
                "UIInterfaceOrientationPortrait": .portrait,
                "UIInterfaceOrientationPortraitUpsideDown": .portraitUpsideDown,
                "UIInterfaceOrientationLandscapeLeft": .landscapeLeft,
                "UIInterfaceOrientationLandscapeRight": .landscapeRight
            ]
            let expected = declared.reduce(into: UIInterfaceOrientationMask()) { $0.formUnion(masks[$1] ?? []) }
            #expect(PlayerOrientationLock.orientations(locked: false, idiom: idiom) == expected)
        }

        @Test func `rotate to landscape is off by default`() {
            #expect(!PlayerSettings.Playback.rotateToLandscapeDefault)
        }
    }
#endif
