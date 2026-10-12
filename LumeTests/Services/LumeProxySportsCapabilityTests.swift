import Foundation
@testable import Lume
import Testing

struct LumeProxySportsCapabilityTests {
    private let sports = #"{"v":1,"matcher_v":3,"source":"espn","competitions":["soccer/eng.1"],"max_batch_size":50,"groups":["fixtures","broadcasts"]}"#

    @Test func `sports negotiates independently of missing or malformed metadata`() throws {
        for metadata in ["null", "true"] {
            let value = try JSONDecoder().decode(LumeProxyCapabilities.self, from: Data("{\"v\":1,\"metadata\":\(metadata),\"sports\":\(sports)}".utf8))
            #expect(value.sportsBatchSize == 50)
            #expect(value.metadataBatchSize == nil)
            #expect(value.sports?.competitions == ["soccer/eng.1"])
        }
    }

    @Test(arguments: ["null", "true", #"{"v":2}"#])
    func `malformed sports never breaks metadata`(_ sports: String) throws {
        let json = "{\"v\":1,\"metadata\":{\"v\":1,\"max_batch_size\":50},\"sports\":\(sports)}"
        let value = try JSONDecoder().decode(LumeProxyCapabilities.self, from: Data(json.utf8))
        #expect(value.metadataBatchSize == 50)
        #expect(value.sportsBatchSize == nil)
    }

    @Test(arguments: ["version", "matcher", "source", "group", "limit", "envelope"])
    func `unsupported sports contract stays on local matching`(_ field: String) throws {
        var json = "{\"v\":1,\"sports\":\(sports)}"
        switch field {
        case "version": json = json.replacingOccurrences(of: "\"v\":1,\"matcher", with: "\"v\":2,\"matcher")
        case "matcher": json = json.replacingOccurrences(of: "\"matcher_v\":3", with: "\"matcher_v\":4")
        case "source": json = json.replacingOccurrences(of: "espn", with: "other")
        case "group": json = json.replacingOccurrences(of: "broadcasts", with: "fixtures")
        case "limit": json = json.replacingOccurrences(of: "\"max_batch_size\":50", with: "\"max_batch_size\":0")
        default: json = json.replacingOccurrences(of: "{\"v\":1,\"sports", with: "{\"v\":2,\"sports")
        }
        let value = try JSONDecoder().decode(LumeProxyCapabilities.self, from: Data(json.utf8))
        #expect(value.sportsBatchSize == nil)
    }
}
