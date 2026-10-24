@testable import Lume
import Testing

struct LaunchSplashPhaseTests {
    @Test func `the hand-over frame is the static launch screen`() {
        let phase = LaunchSplashPhase.handOver
        #expect(!phase.isColoured)
        #expect(!phase.showsGlows)
        #expect(!phase.showsWordmark)
        #expect(phase.markMotion == .launch)
    }

    @Test func `colour and glows arrive together, then the wordmark, then the wait pulse`() {
        let phases = LaunchSplashPhase.timeline(reduceMotion: false).map(\.phase)
        #expect(phases == [.colouring, .branded, .waiting])
        #expect(LaunchSplashPhase.colouring.isColoured && LaunchSplashPhase.colouring.showsGlows)
        #expect(!LaunchSplashPhase.colouring.showsWordmark)
        #expect(LaunchSplashPhase.waiting.markMotion == .pulse)
    }

    @Test(arguments: [false, true])
    func `the timeline only moves forward`(reduceMotion: Bool) {
        let steps = LaunchSplashPhase.timeline(reduceMotion: reduceMotion)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0.seconds <= $1.seconds && $0.phase < $1.phase })
    }

    @Test func `with Reduce Motion the wordmark is there at once`() {
        let branded = LaunchSplashPhase.timeline(reduceMotion: true).first { $0.phase == .branded }
        #expect(branded?.seconds == 0)
    }
}
