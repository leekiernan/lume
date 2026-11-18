@testable import Lume
import Testing

nonisolated struct PlayerControlsFocusMachineTests {
    private enum Focus: CaseIterable {
        case transport, scrubber, tab, panel, episode, channel
        case audio, subtitles, source, hue, favorite
    }

    private static let menus: Set<Focus> = [.audio, .subtitles, .source, .hue, .favorite]

    @Test func `unacquired focus never opens a menu or prevents an inactivity deadline`() throws {
        var owner = PlayerControlsFocusMachine<Focus>()
        var chrome = PlayerChromeMachine()
        for _ in 0 ..< 3 {
            owner.focusChanged(to: nil, menuTriggers: Self.menus)
            #expect(owner.needsLanding && !owner.isMenuOpen)
        }
        if owner.isMenuOpen { chrome.menuOpened() }
        let scheduled = chrome.schedule(.inactivity, mayHide: true)
        let request = try #require(scheduled)
        let hidden = chrome.fire(request, mayHide: true)
        #expect(hidden)
        #expect(!chrome.isVisible)
    }

    @Test func `losing ordinary controls requests focus and still times out`() throws {
        for target in Focus.allCases where !Self.menus.contains(target) {
            var owner = PlayerControlsFocusMachine<Focus>()
            var chrome = PlayerChromeMachine()
            owner.focusChanged(to: target, menuTriggers: Self.menus)
            #expect(!owner.needsLanding && !owner.isMenuOpen)
            owner.focusChanged(to: nil, menuTriggers: Self.menus)
            if owner.isMenuOpen { chrome.menuOpened() }
            #expect(owner.needsLanding && !owner.isMenuOpen)
            let scheduled = chrome.schedule(.inactivity, mayHide: true)
            let request = try #require(scheduled)
            let hidden = chrome.fire(request, mayHide: true)
            #expect(hidden)
        }
    }

    @Test func `native menu handoffs pin controls until focus returns`() throws {
        for target in Self.menus {
            var owner = PlayerControlsFocusMachine<Focus>()
            var chrome = PlayerChromeMachine()
            let scheduled = chrome.schedule(.inactivity, mayHide: true)
            let old = try #require(scheduled)
            owner.focusChanged(to: target, menuTriggers: Self.menus)
            owner.focusChanged(to: nil, menuTriggers: Self.menus)
            #expect(owner.isMenuOpen && !owner.needsLanding)
            chrome.menuOpened()
            owner.focusChanged(to: nil, menuTriggers: Self.menus)
            #expect(owner.isMenuOpen && !owner.needsLanding)
            let staleFire = chrome.fire(old, mayHide: true)
            let pinned = chrome.schedule(.inactivity, mayHide: true)
            #expect(!staleFire && pinned == nil)
            owner.focusChanged(to: target, menuTriggers: Self.menus)
            #expect(!owner.isMenuOpen && !owner.needsLanding)
            chrome.menuClosed()
            let renewed = chrome.schedule(.inactivity, mayHide: true)
            let fresh = try #require(renewed)
            let hidden = chrome.fire(fresh, mayHide: true)
            #expect(hidden)
        }
    }

    @Test func `a removed menu trigger cannot leave the controls pinned`() {
        for target in Self.menus {
            var owner = PlayerControlsFocusMachine<Focus>()
            owner.focusChanged(to: target, menuTriggers: Self.menus)
            owner.focusChanged(to: nil, menuTriggers: Self.menus.subtracting([target]))
            #expect(owner.needsLanding && !owner.isMenuOpen)
            owner.focusChanged(to: target, menuTriggers: Self.menus)
            owner.focusChanged(to: nil, menuTriggers: Self.menus)
            #expect(owner.isMenuOpen)
            owner.focusChanged(to: nil, menuTriggers: Self.menus.subtracting([target]))
            #expect(owner.needsLanding && !owner.isMenuOpen)
        }
    }

    @Test func `focus return and a fresh reveal do not inherit the previous menu owner`() {
        var owner = PlayerControlsFocusMachine<Focus>()
        owner.focusChanged(to: .audio, menuTriggers: Self.menus)
        owner.focusChanged(to: nil, menuTriggers: Self.menus)
        owner.focusChanged(to: .transport, menuTriggers: Self.menus)
        owner.focusChanged(to: nil, menuTriggers: Self.menus)
        #expect(owner.needsLanding && !owner.isMenuOpen)
        owner.focusChanged(to: .audio, menuTriggers: Self.menus)
        owner.focusChanged(to: nil, menuTriggers: Self.menus)
        let nextReveal = PlayerControlsFocusMachine<Focus>()
        #expect(nextReveal.needsLanding && !nextReveal.isMenuOpen)
    }

    @Test func `a declined focus request cannot rearm itself or postpone inactivity`() throws {
        var owner = PlayerControlsFocusMachine<Focus>()
        var chrome = PlayerChromeMachine()
        let scheduled = chrome.schedule(.inactivity, mayHide: true)
        let deadline = try #require(scheduled)
        let landing = try #require(owner.landingRequest)
        owner.beginLanding()
        #expect(owner.landingRequest == landing && !owner.needsLanding)
        // FocusState reports our requested value, then UIKit declines it.
        let landingEffect = owner.focusChanged(to: .transport, menuTriggers: Self.menus)
        let rejectedEffect = owner.focusChanged(to: nil, menuTriggers: Self.menus)
        #expect(landingEffect == nil && rejectedEffect == nil)
        #expect(owner.landingRequest == nil && !owner.needsLanding && !owner.isMenuOpen)
        for _ in 0 ..< 3 {
            let absentEffect = owner.focusChanged(to: nil, menuTriggers: Self.menus)
            let menuEffect = owner.menuTriggersChanged(Self.menus)
            #expect(absentEffect == nil && menuEffect == nil)
            #expect(owner.landingRequest == nil)
        }
        let hidden = chrome.fire(deadline, mayHide: true)
        #expect(hidden)
        #expect(!chrome.isVisible)
        // A later real movement can establish a new focus acquisition episode.
        let movement = owner.focusChanged(to: .scrubber, menuTriggers: Self.menus)
        #expect(movement == .activity)
        owner.focusChanged(to: nil, menuTriggers: Self.menus)
        #expect(owner.needsLanding && owner.landingRequest != landing)
    }
}

@MainActor
struct PlayerControlsFocusLandingTests {
    @Test(arguments: [false, true])
    func `a delayed focus request never steals focus claimed while it settles`(opensMenu: Bool) async {
        var owner = PlayerControlsFocusMachine<Int>()
        var asserted = false
        let menus: Set = [1]
        let claimed = await TVFocusLanding.perform(release: {}, assert: {
            owner.beginLanding()
            asserted = true
        }, while: { owner.needsLanding }, settle: {
            owner.focusChanged(to: 1, menuTriggers: menus)
            if opensMenu { owner.focusChanged(to: nil, menuTriggers: menus) }
        })
        #expect(!claimed && !asserted)
        #expect(owner.isMenuOpen == opensMenu)
    }
}
