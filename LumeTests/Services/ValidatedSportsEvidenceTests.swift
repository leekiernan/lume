import Foundation
@testable import Lume
import Testing

struct ValidatedSportsEvidenceTests {
    let kickoff = Date(timeIntervalSince1970: 100_000)

    @Test func `timed evidence retains typed source pairing and interval`() throws {
        let evidence = LumeSportsEvidence(source: "supplement:uk", field: "subtitle", text: "Arsenal v Lille", strength: "explicit_pairing",
                                          classification: "live", programmeID: "programme", start: kickoff, stop: kickoff.addingTimeInterval(7200))
        guard case let .timed(value) = try #require(evidence.validated(kickoff: kickoff)) else {
            Issue.record("Expected a timed match")
            return
        }
        #expect(value.source == .supplement("uk") && value.start == kickoff && value.programmeID == "programme")
        guard case .explicit(.subtitle) = value.pairing else { Issue.record("Expected subtitle pairing"); return }
    }

    @Test(arguments: ["supplement:", "provider_channel", "unrecognized"])
    func `invalid timed sources cannot reach matching`(_ source: String) {
        let evidence = LumeSportsEvidence(source: source, field: "title", text: "A v B", strength: "explicit_pairing", classification: "live",
                                          programmeID: "p", start: kickoff, stop: kickoff.addingTimeInterval(3600))
        #expect(evidence.validated(kickoff: kickoff) == nil)
    }

    @Test func `untimed suggestions cannot carry a programme start`() throws {
        let untimed = LumeSportsEvidence(source: "provider_channel", field: "name", text: "A v B", strength: "untimed_channel_pairing",
                                         classification: "unknown", programmeID: nil, start: nil, stop: nil)
        let validated = try #require(untimed.validated(kickoff: kickoff))
        #expect(validated.start == nil)
        let inconsistent = LumeSportsEvidence(source: "provider_channel", field: "name", text: "A v B", strength: "untimed_channel_pairing",
                                              classification: "unknown", programmeID: nil, start: kickoff, stop: nil)
        #expect(inconsistent.validated(kickoff: kickoff) == nil)
    }
}
