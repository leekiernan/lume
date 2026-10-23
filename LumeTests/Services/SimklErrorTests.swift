import Foundation
@testable import Lume
import Testing

struct SimklErrorTests {
    @Test(arguments: [
        SimklError.notConfigured, .invalidResponse, .server(403), .decoding, .notAuthenticated,
        .itemNotFound, .authorizationPending, .slowDown, .codeExpired, .invalidClient
    ])
    func `every Simkl error has an explicit diagnostic`(error: SimklError) {
        #expect(LogRedaction.describe(error) == "SimklError: \(error.logDescription)")
        #expect(!error.logDescription.isEmpty)
        #expect(!LogRedaction.describe(error).contains("operation couldn’t be completed"))
    }

    @Test func `API token rejection and OAuth client rejection remain distinct`() {
        #expect(LogRedaction.describe(SimklError.notAuthenticated) == "SimklError: not authenticated (HTTP 401)")
        #expect(LogRedaction.describe(SimklError.invalidClient) == "SimklError: OAuth client rejected (HTTP 401)")
        #expect(LogRedaction.describe(SimklError.server(403)) == "SimklError: HTTP 403")
    }
}
