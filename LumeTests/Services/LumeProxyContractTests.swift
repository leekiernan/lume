import Foundation
@testable import Lume
import Testing

/// The proxy's own fixtures (`docs/lume-api.md` in the proxy repo), copied
/// unchanged into `Fixtures/ProxyMetadata`. Never hand-edit them to pass.
struct LumeProxyContractTests {
    private final class ResourceAnchor {}

    private static func fixtureURL(_ name: String, _ ext: String) -> URL {
        let bundle = Bundle(for: ResourceAnchor.self)
        let sourceURL = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ProxyMetadata/\(name).\(ext)")
        return bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/ProxyMetadata")
            ?? bundle.url(forResource: name, withExtension: ext) ?? sourceURL
    }

    private static func capabilities(_ json: String) throws -> LumeProxyCapabilities {
        try JSONDecoder().decode(LumeProxyCapabilities.self, from: Data(json.utf8))
    }

    // MARK: Metadata budgets

    @Test func `the proxy's capability fixture fits the app's budgets`() throws {
        let data = try Data(contentsOf: Self.fixtureURL("lume-capabilities-metadata", "json"))
        let capabilities = try JSONDecoder().decode(LumeProxyCapabilities.self, from: data)
        let metadata = try #require(capabilities.metadata)
        #expect(metadata.refetchAfter == 13 * 24 * 3600)
        #expect(metadata.wait == 3)
        #expect(capabilities.metadataBatchSize == 50)
        #expect(capabilities.metadataRequestTimeout == 5)
    }

    @Test func `an older proxy without the fields keeps today's budgets`() throws {
        let capabilities = try Self.capabilities(#"{"v":1,"metadata":{"v":1,"max_batch_size":50}}"#)
        #expect(capabilities.metadataBatchSize == 50)
        #expect(capabilities.metadataRequestTimeout == 5)
    }

    @Test func `a longer wait lengthens the request, within the session's limit`() throws {
        let capabilities = try Self.capabilities(#"{"v":1,"metadata":{"v":1,"max_batch_size":50,"wait_ms":6000}}"#)
        #expect(capabilities.metadataBatchSize == 50)
        #expect(capabilities.metadataRequestTimeout == 8)
    }

    @Test(arguments: [
        #"{"v":1,"metadata":{"v":1,"max_batch_size":50,"refetch_after_s":1209600}}"#, // the app's whole window
        #"{"v":1,"metadata":{"v":1,"max_batch_size":50,"wait_ms":9000}}"#, // no room to transfer
        #"{"v":1,"metadata":{"v":1,"max_batch_size":50,"refetch_after_s":0}}"#
    ])
    func `metadata outside the app's budgets is declined, not timed out or discarded`(_ json: String) throws {
        let capabilities = try Self.capabilities(json)
        #expect(capabilities.metadataBatchSize == nil)
        #expect(!capabilities.offersRatings)
    }

    // MARK: Guide

    @Test func `the published guide names the supplements the relay applied`() {
        var programmes: [ParsedProgramme] = []
        let outcome = XMLTVParser.parse(fileURL: Self.fixtureURL("lume-guide-supplemented", "xml"), preferredLanguage: nil) { programmes += $0 }
        #expect(outcome.succeeded)
        #expect(outcome.relaySupplements == ["epgshare-uk", "epgshare-us-locals"])
        #expect(programmes.first?.subtitle == "Part 1")
        let known = Set(EPGEnrichmentFeed.Identifier.allCases.map(\.relayID))
        #expect(outcome.relaySupplements.isSubset(of: known))
    }

    @Test(arguments: [
        #"<tv generator-info-name="panel"><channel id="a"/></tv>"#,
        #"<tv lume-supplements=""><channel id="a"/></tv>"#,
        #"<html lume-supplements="epgshare-uk"><body/></html>"#
    ])
    func `a guide without the attribute, or not a guide, claims nothing`(_ document: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xml")
        try Data(document.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(XMLTVParser.parse(fileURL: url) { _ in }.relaySupplements.isEmpty)
    }
}
