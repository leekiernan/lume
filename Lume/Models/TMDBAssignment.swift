import Foundation

/// The effective identity and the response responsible for it travel together.
/// Absence is explicitly unknown legacy provenance, not a guessed catalogue ID.
nonisolated struct TMDBAssignment: Codable, Equatable {
    enum Origin: String, Codable { case catalogue, providerDetails, deviceSearch }

    let identity: TMDBTitleReference
    let origin: Origin
}

nonisolated extension EnrichedTitle {
    var tmdbAssignment: TMDBAssignment? {
        guard let tmdbAssignmentData,
              let value = try? JSONDecoder().decode(TMDBAssignment.self, from: tmdbAssignmentData),
              value.identity == metadataIdentity else { return nil }
        return value
    }

    func assignTMDB(_ identity: TMDBTitleReference, origin: TMDBAssignment.Origin) {
        guard identity.kind == (self is Movie ? .movie : .series) else { return }
        if tmdbId != identity.rawValue {
            if tmdbId != nil { forgetTMDBEnrichment() }
            tmdbId = identity.rawValue
        }
        let assignment = TMDBAssignment(identity: identity, origin: origin)
        guard tmdbAssignment != assignment else { return }
        tmdbAssignmentData = try? JSONEncoder().encode(assignment)
    }
}
