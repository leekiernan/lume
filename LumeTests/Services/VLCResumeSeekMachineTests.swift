import Foundation
@testable import Lume
import Testing

struct VLCResumeSeekMachineTests {
    @Test func `resume waits for seekability and issues exactly once`() {
        var resume = VLCResumeSeekMachine(target: 120)
        let seek1 = resume.seekIfPossible(isSeekable: false)
        #expect(seek1 == nil)
        let observed1 = resume.observe(currentSeconds: 120)
        #expect(!observed1) // No seek was issued.
        let seek2 = resume.seekIfPossible(isSeekable: true)
        #expect(seek2 == 120)
        let seek3 = resume.seekIfPossible(isSeekable: true)
        #expect(seek3 == nil)
        let observed2 = resume.observe(currentSeconds: 0)
        #expect(!observed2)
        let observed3 = resume.observe(currentSeconds: 117)
        #expect(!observed3)
        let observed4 = resume.observe(currentSeconds: 118)
        #expect(observed4)
        #expect(resume.state == .landed)
        let observed5 = resume.observe(currentSeconds: 1)
        #expect(observed5) // A later user seek is allowed.
    }

    @Test func `reload and reconnect reset seek issuance and landing`() {
        var resume = VLCResumeSeekMachine(target: 120)
        let seek4 = resume.seekIfPossible(isSeekable: true)
        #expect(seek4 == 120)
        let observed6 = resume.observe(currentSeconds: 120)
        #expect(observed6)
        resume = VLCResumeSeekMachine(target: 200)
        let observed7 = resume.observe(currentSeconds: 0)
        #expect(!observed7)
        let seek5 = resume.seekIfPossible(isSeekable: true)
        #expect(seek5 == 200)
        let observed8 = resume.observe(currentSeconds: 200)
        #expect(observed8)
        resume = VLCResumeSeekMachine(target: 0, isLive: true)
        let observed9 = resume.observe(currentSeconds: 0)
        #expect(observed9)
        let seek6 = resume.seekIfPossible(isSeekable: true)
        #expect(seek6 == nil)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -1, 0, 1, Double(Int32.max)])
    func `invalid or negligible resume points never reach VLCTime`(_ target: Double) {
        var resume = VLCResumeSeekMachine(target: target)
        #expect(resume.state == .notNeeded)
        let seek7 = resume.seekIfPossible(isSeekable: true)
        #expect(seek7 == nil)
        let observed10 = resume.observe(currentSeconds: 0)
        #expect(observed10)
    }

    @Test func `nonfinite clock samples cannot settle a resume`() {
        var resume = VLCResumeSeekMachine(target: 120)
        let seek8 = resume.seekIfPossible(isSeekable: true)
        #expect(seek8 == 120)
        let observed11 = resume.observe(currentSeconds: .infinity)
        #expect(!observed11)
        let observed12 = resume.observe(currentSeconds: .nan)
        #expect(!observed12)
        #expect(resume.state == .issued(120))
    }
}
