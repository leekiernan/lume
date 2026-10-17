import Foundation
@testable import Lume
import Testing

struct VLCResumeSeekMachineTests {
    @Test func `resume waits for seekability and issues exactly once`() {
        var resume = VLCResumeSeekMachine(target: 120)
        #expect(resume.seekIfPossible(isSeekable: false) == nil)
        let beforeSeek = resume.observe(currentSeconds: 120)
        #expect(!beforeSeek) // No seek was issued.
        #expect(resume.seekIfPossible(isSeekable: true) == 120)
        #expect(resume.seekIfPossible(isSeekable: true) == nil)
        let initialClock = resume.observe(currentSeconds: 0)
        #expect(!initialClock)
        let tooEarly = resume.observe(currentSeconds: 117)
        #expect(!tooEarly)
        let landed = resume.observe(currentSeconds: 118)
        #expect(landed)
        #expect(resume.state == .landed)
        let afterUserSeek = resume.observe(currentSeconds: 1)
        #expect(afterUserSeek) // A later user seek is allowed.
    }

    @Test func `reload and reconnect reset seek issuance and landing`() {
        var resume = VLCResumeSeekMachine(target: 120)
        #expect(resume.seekIfPossible(isSeekable: true) == 120)
        let firstLanded = resume.observe(currentSeconds: 120)
        #expect(firstLanded)
        resume = VLCResumeSeekMachine(target: 200)
        let reloadClock = resume.observe(currentSeconds: 0)
        #expect(!reloadClock)
        #expect(resume.seekIfPossible(isSeekable: true) == 200)
        let reloadLanded = resume.observe(currentSeconds: 200)
        #expect(reloadLanded)
        resume = VLCResumeSeekMachine(target: 0, isLive: true)
        let liveClock = resume.observe(currentSeconds: 0)
        #expect(liveClock)
        #expect(resume.seekIfPossible(isSeekable: true) == nil)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -1, 0, 1, Double(Int32.max)])
    func `invalid or negligible resume points never reach VLCTime`(_ target: Double) {
        var resume = VLCResumeSeekMachine(target: target)
        #expect(resume.state == .notNeeded)
        #expect(resume.seekIfPossible(isSeekable: true) == nil)
        let initialClock = resume.observe(currentSeconds: 0)
        #expect(initialClock)
    }

    @Test func `nonfinite clock samples cannot settle a resume`() {
        var resume = VLCResumeSeekMachine(target: 120)
        #expect(resume.seekIfPossible(isSeekable: true) == 120)
        let infiniteClock = resume.observe(currentSeconds: .infinity)
        #expect(!infiniteClock)
        let invalidClock = resume.observe(currentSeconds: .nan)
        #expect(!invalidClock)
        #expect(resume.state == .issued(120))
    }
}
