import Foundation
@testable import Lume
import Testing

/// Explicit system integration check, separate from asset-independent units.
/// Run on a host with Apple's English sentence assets using the invocation in
/// docs/test-suite-validation.md. The regular suite does not download models.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LUME_TEST_SYSTEM_EMBEDDINGS"] == "1"))
struct SystemEmbeddingIntegrationTests {
    @Test func `the system sentence model separates genres and has its own vector space`() async throws {
        let sentence = try await TextEmbedder.sentence()
        try await sentence.prepare()
        func vector(_ text: String) throws -> [Float] {
            let embedded = try sentence.vector(for: text)
            return try #require(embedded)
        }
        let nemo = try vector("Finding Nemo (2003). Animation, Family, Adventure.")
        let toyStory = try vector("Toy Story (1995). Animation, Family, Adventure.")
        let godfather = try vector("The Godfather (1972). Crime, Drama.")
        #expect(RecommendationScoring.cosineSimilarity(nemo, toyStory)
            > RecommendationScoring.cosineSimilarity(nemo, godfather))
        #expect(sentence.prefersShortDocuments)
        if let contextual = try? await TextEmbedder.contextual() {
            #expect(sentence.spaceID != contextual.spaceID)
            #expect(!contextual.prefersShortDocuments)
        }
        sentence.unload()
    }
}
