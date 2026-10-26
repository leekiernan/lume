@testable import Lume
import SwiftUI
import Testing

struct PlayerKeyCommandTests {
    @Test func `bare keys map to the player's commands`() {
        let pairs: [(KeyEquivalent, PlayerKeyCommand)] = [
            (.space, .togglePlay), (.leftArrow, .skipBackward), (.rightArrow, .skipForward),
            (.upArrow, .nextChannel), (.downArrow, .previousChannel), ("f", .toggleFullScreen), (.escape, .close)
        ]
        for (key, command) in pairs {
            #expect(PlayerKeyCommand(key: key, modifiers: []) == command)
        }
        #expect(PlayerKeyCommand(key: "x", modifiers: []) == nil)
    }

    @Test func `chords are left to the system and the menu bar`() {
        for modifiers: EventModifiers in [.command, .option, .control, .shift] {
            #expect(PlayerKeyCommand(key: .space, modifiers: modifiers) == nil)
            #expect(PlayerKeyCommand(key: .leftArrow, modifiers: modifiers) == nil)
        }
    }

    @Test func `caps lock and the arrow keys' own flags don't make a chord`() {
        #expect(PlayerKeyCommand(key: "F", modifiers: .capsLock) == .toggleFullScreen)
        #expect(PlayerKeyCommand(key: .upArrow, modifiers: [.numericPad, .function]) == .nextChannel)
    }

    @Test func `held seeks and channel steps repeat, toggles don't`() {
        #expect(PlayerKeyCommand.skipForward.repeats && PlayerKeyCommand.nextChannel.repeats)
        #expect(!PlayerKeyCommand.togglePlay.repeats && !PlayerKeyCommand.toggleFullScreen.repeats && !PlayerKeyCommand.close.repeats)
    }
}
