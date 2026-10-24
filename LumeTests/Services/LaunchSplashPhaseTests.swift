@testable import Lume
import Testing

struct LaunchSplashPhaseTests {
    @Test func `the hand-over frame is the plain launch screen`() {
        let phase = LaunchSplashPhase.handOver
        #expect(!phase.showsGlows)
        #expect(!phase.showsWordmark)
        #expect(phase.markMotion == .launch)
    }

    @Test(arguments: LumeLogo.allCases)
    func `the glows come in with the mark, then the wordmark at the logo's time, then the wait pulse`(logo: LumeLogo) {
        let steps = LaunchSplashPhase.timeline(for: logo, reduceMotion: false)
        #expect(steps.map(\.phase) == [.launching, .branded, .waiting])
        #expect(steps[1].seconds == logo.launch.wordmark.start)
        #expect(LaunchSplashPhase.launching.showsGlows && !LaunchSplashPhase.launching.showsWordmark)
        #expect(LaunchSplashPhase.waiting.markMotion == .pulse)
    }

    @Test(arguments: [false, true])
    func `the timeline only moves forward`(reduceMotion: Bool) {
        for logo in LumeLogo.allCases {
            let steps = LaunchSplashPhase.timeline(for: logo, reduceMotion: reduceMotion)
            #expect(zip(steps, steps.dropFirst()).allSatisfy { $0.seconds <= $1.seconds && $0.phase < $1.phase })
        }
    }

    @Test func `with Reduce Motion the wordmark is there at once`() {
        let branded = LaunchSplashPhase.timeline(for: .floodlight, reduceMotion: true).first { $0.phase == .branded }
        #expect(branded?.seconds == 0)
    }
}
