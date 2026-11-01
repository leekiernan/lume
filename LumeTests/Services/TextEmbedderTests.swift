//
//  TextEmbedderTests.swift
//  LumeTests
//
//  Covers the two-backend embedder and the vector-space bookkeeping that keeps
//  the recommendation engine from comparing vectors it cannot compare.
//
//  Model discovery is injected: simulator runtimes do not always include
//  Apple's sentence assets. These tests verify our adapter and space handling;
//  semantic quality of Apple's model requires a host with the actual assets.
//

import Foundation
@testable import Lume
import Testing

struct TextEmbedderTests {
    // MARK: - Backends

    @Test func `sentence backend needs no assets and no prepare`() async throws {
        let embedder = try await sentence()
        // Must not hang, throw or reach the network — this is the whole point
        // of the backend on tvOS, where contextual assets are never served.
        try await embedder.prepare()
        let embedded = try embedder.vector(for: "Inception (2010). Action, Science Fiction.")
        let vector = try #require(embedded)
        #expect(vector.count > 0)
        #expect(vector.contains { $0 != 0 })
        #expect(vector == [0.25, 0.5, 0.75])
    }

    @Test func `sentence adapter forwards the document and preserves a missing vector`() async throws {
        let embedder = try await TextEmbedder.sentence(lookup: {
            SentenceFixture(vector: { $0 == "Exact document" ? [0.125, -0.5, 1] : nil })
        })
        #expect(try embedder.vector(for: "Exact document") == [0.125, -0.5, 1])
        #expect(try embedder.vector(for: "Missing document") == nil)
    }

    @Test func `sentence backend prefers short documents`() async throws {
        let embedder = try await sentence()
        #expect(embedder.prefersShortDocuments)
    }

    @Test func `sentence vector spaces include the models dimension`() async throws {
        let first = try await sentence()
        let second = try await TextEmbedder.sentence(lookup: { SentenceFixture(dimension: 512) })
        #expect(first.spaceID == "sentence-en-3")
        #expect(second.spaceID == "sentence-en-512")
        #expect(first.spaceID != second.spaceID)
    }

    @Test func `unavailable sentence assets fail explicitly without choosing another backend`() async {
        await #expect(throws: TextEmbedder.EmbedderError.modelUnavailable) {
            try await TextEmbedder.sentence(lookup: { nil }, retryDelays: [])
        }
    }

    @Test func `unload is safe on a backend that was never prepared`() async throws {
        let first = try await sentence()
        let second = try await sentence()
        first.unload()
        second.unload()
    }

    // MARK: - Space bookkeeping

    @Test func `first run has nothing to invalidate`() throws {
        let defaults = try makeDefaults()
        #expect(EmbeddingSpaceStore.current(in: defaults) == nil)
        #expect(!EmbeddingSpaceStore.needsReset(to: "sentence-en-512", in: defaults))
    }

    @Test func `same space needs no reset`() throws {
        let defaults = try makeDefaults()
        EmbeddingSpaceStore.set("sentence-en-512", in: defaults)
        #expect(!EmbeddingSpaceStore.needsReset(to: "sentence-en-512", in: defaults))
    }

    @Test func `changed space needs a reset`() throws {
        let defaults = try makeDefaults()
        EmbeddingSpaceStore.set("sentence-en-512", in: defaults)
        #expect(EmbeddingSpaceStore.needsReset(to: "contextual-ABC", in: defaults))

        EmbeddingSpaceStore.set("contextual-ABC", in: defaults)
        #expect(!EmbeddingSpaceStore.needsReset(to: "contextual-ABC", in: defaults))
        #expect(EmbeddingSpaceStore.current(in: defaults) == "contextual-ABC")
    }

    // MARK: - Helpers

    private func sentence() async throws -> TextEmbedder {
        try await TextEmbedder.sentence(lookup: { SentenceFixture() })
    }

    /// A private suite so the tests never touch (or race on) the app's
    /// `UserDefaults.standard`.
    private func makeDefaults() throws -> UserDefaults {
        let name = "TextEmbedderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

private nonisolated struct SentenceFixture: SentenceEmbeddingModel {
    var dimension = 3
    var vector: (String) -> [Double]? = { _ in [0.25, 0.5, 0.75] }

    func vector(for text: String) -> [Double]? {
        vector(text)
    }
}
