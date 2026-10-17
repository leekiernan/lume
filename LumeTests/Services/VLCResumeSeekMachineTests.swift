import Foundation
@testable import Lume
import Testing

struct VLCResumeSeekMachineTests {
    @Test func `resume waits for seekability and issues exactly once`() {
        var resume = VLCResumeSeekMachine(target: 120)
        #expect(resume.seekIfPossible(isSeekable: false) == nil)
        let transition1 = resume.observe(currentSeconds: 120)
        #expect(!transition1) // No seek was issued.
        #expect(resume.seekIfPossible(isSeekable: true) == 120)
        #expect(resume.seekIfPossible(isSeekable: true) == nil)
        let transition2 = resume.observe(currentSeconds: 0)
        #expect(!transition2)
        let transition3 = resume.observe(currentSeconds: 117)
        #expect(!transition3)
        let transition4 = resume.observe(currentSeconds: 118)
        #expect(transition4)
        #expect(resume.state == .landed)
        let transition5 = resume.observe(currentSeconds: 1)
        #expect(transition5) // A later user seek is allowed.
    }

    @Test func `reload and reconnect reset seek issuance and landing`() {
        var resume = VLCResumeSeekMachine(target: 120)
        #expect(resume.seekIfPossible(isSeekable: true) == 120)
        let transition6 = resume.observe(currentSeconds: 120)
        #expect(transition6)
        resume = VLCResumeSeekMachine(target: 200)
        let transition7 = resume.observe(currentSeconds: 0)
        #expect(!transition7)
        #expect(resume.seekIfPossible(isSeekable: true) == 200)
        let transition8 = resume.observe(currentSeconds: 200)
        #expect(transition8)
        resume = VLCResumeSeekMachine(target: 0, isLive: true)
        let transition9 = resume.observe(currentSeconds: 0)
        #expect(transition9)
        #expect(resume.seekIfPossible(isSeekable: true) == nil)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -1, 0, 1, Double(Int32.max)])
    func `invalid or negligible resume points never reach VLCTime`(_ target: Double) {
        var resume = VLCResumeSeekMachine(target: target)
        #expect(resume.state == .notNeeded)
        #expect(resume.seekIfPossible(isSeekable: true) == nil)
        let transition10 = resume.observe(currentSeconds: 0)
        #expect(transition10)
    }

    @Test func `nonfinite clock samples cannot settle a resume`() {
        var resume = VLCResumeSeekMachine(target: 120)
        #expect(resume.seekIfPossible(isSeekable: true) == 120)
        let transition11 = resume.observe(currentSeconds: .infinity)
        #expect(!transition11)
        let transition12 = resume.observe(currentSeconds: .nan)
        #expect(!transition12)
        #expect(resume.state == .issued(120))
    }
}
