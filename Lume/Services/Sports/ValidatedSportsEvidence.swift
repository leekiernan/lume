import Foundation

/// The resolver never interprets raw wire strings. Timed matches always have a
/// programme interval; untimed channel suggestions cannot masquerade as one.
nonisolated enum ValidatedSportsEvidence {
    enum Classification: String { case live, unknown }
    enum Source: Equatable {
        case provider
        case supplement(String)
    }

    enum HeadlineField: String { case title, subtitle }
    enum Pairing {
        case explicit(HeadlineField)
        case description
    }

    struct Timed {
        let source: Source
        let pairing: Pairing
        let classification: Classification
        let programmeID: String
        let start: Date
        let stop: Date

        fileprivate init(source: Source, pairing: Pairing, classification: Classification, programmeID: String, start: Date, stop: Date) {
            self.source = source
            self.pairing = pairing
            self.classification = classification
            self.programmeID = programmeID
            self.start = start
            self.stop = stop
        }
    }

    case timed(Timed)
    case untimedChannelPairing(Classification)

    var start: Date? {
        guard case let .timed(value) = self else { return nil }
        return value.start
    }
}

nonisolated extension LumeSportsEvidence {
    func validated(kickoff: Date) -> ValidatedSportsEvidence? {
        guard !text.isEmpty, text.count <= 4096,
              let classification = ValidatedSportsEvidence.Classification(rawValue: classification) else { return nil }
        if strength == "untimed_channel_pairing" {
            guard source == "provider_channel", field == "name", start == nil, stop == nil, programmeID == nil else { return nil }
            return .untimedChannelPairing(classification)
        }
        let origin: ValidatedSportsEvidence.Source
        if source == "provider" {
            origin = .provider
        } else if source.hasPrefix("supplement:"), source.count > "supplement:".count {
            origin = .supplement(String(source.dropFirst("supplement:".count)))
        } else { return nil }
        let pairing: ValidatedSportsEvidence.Pairing
        if strength == "explicit_pairing", let headline = ValidatedSportsEvidence.HeadlineField(rawValue: field) {
            pairing = .explicit(headline)
        } else if strength == "description_pairing", field == "description" {
            pairing = .description
        } else { return nil }
        guard let programmeID, !programmeID.isEmpty, let start, let stop,
              start >= kickoff.addingTimeInterval(-SportsMatcher.leadTime),
              start <= kickoff.addingTimeInterval(SportsMatcher.lateStart), stop > kickoff, stop > start else { return nil }
        return .timed(.init(source: origin, pairing: pairing, classification: classification, programmeID: programmeID, start: start, stop: stop))
    }
}
