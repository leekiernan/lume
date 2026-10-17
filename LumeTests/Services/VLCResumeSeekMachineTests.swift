import Foundation
@testable import Lume
import Testing

struct VLCResumeSeekMachineTests {
    @Test func `resume waits for seekability and issues exactly once`() {
        var resume = VLCResumeSeekMachine(target: 120)
        #expect(resume.seekIfPossible(isSeekable: false) == nil)
        #expect(!resume.observe(currentSeconds: 120)) // No seek was issued.
        #expect(resume.seekIfPossible(isSeekable: true) == 120)
        #expect(resume.seekIfPossible(isSeekable: true) == nil)
        #expect(!resume.observe(currentSeconds: 0))
        #expect(!resume.observe(currentSeconds: 117))
        #expect(resume.observe(currentSeconds: 118))
        #expect(resume.state == .landed)
        #expect(resume.observe(currentSeconds: 1)) // A later user seek is allowed.
    }

    @Test func `reload and reconnect reset seek issuance and landing`() {
        var resume = VLCResumeSeekMachine(target: 120)
        #expect(resume.seekIfPossible(isSeekable: true) == 120)
        #expect(resume.observe(currentSeconds: 120))
        resume = VLCResumeSeekMachine(target: 200)
        #expect(!resume.observe(currentSeconds: 0))
        #expect(resume.seekIfPossible(isSeekable: true) == 200)
        #expect(resume.observe(currentSeconds: 200))
        resume = VLCResumeSeekMachine(target: 0, isLive: true)
        #expect(resume.observe(currentSeconds: 0))
        #expect(resume.seekIfPossible(isSeekable: true) == nil)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity, -1, 0, 1, Double(Int32.max)])
    func `invalid or negligible resume points never reach VLCTime`(_ target: Double) {
        var resume = VLCResumeSeekMachine(target: target)
        #expect(resume.state == .notNeeded)
        #expect(resume.seekIfPossible(isSeekable: true) == nil)
        #expect(resume.observe(currentSeconds: 0))
    }

    @Test func `nonfinite clock samples cannot settle a resume`() {
        var resume = VLCResumeSeekMachine(target: 120)
        #expect(resume.seekIfPossible(isSeekable: true) == 120)
        #expect(!resume.observe(currentSeconds: .infinity))
        #expect(!resume.observe(currentSeconds: .nan))
        #expect(resume.state == .issued(120))
    }
}
