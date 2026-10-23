import Foundation
@testable import Lume
import Testing

struct TrackerDiagnosticsTests {
    @Test func `only known Simkl error identifiers enter diagnostics`() {
        for code in ["invalid_token", "invalid_grant", "insufficient_scope", "invalid_client"] {
            #expect(TrackerDiagnostics.simklErrorCode(code) == code)
        }
        for code in [nil, "server echoed secret-token", "Bearer secret", "https://host/?token=secret"] as [String?] {
            #expect(TrackerDiagnostics.simklErrorCode(code) == "unrecognized")
        }
    }

    @Test func `token diagnostics report only timing metadata`() {
        let tokens = MetadataOnlyTokens()
        #expect(TrackerDiagnostics.tokenSummary(tokens) == "issued=1970-01-01T00:00:00Z, expires=1970-01-08T00:00:00Z, refreshDue=true")
    }

    @Test func `invalid timing metadata is safe to describe`() {
        #expect(TrackerDiagnostics.tokenSummary(MetadataOnlyTokens(issuedAt: .nan)) == "invalid credential timestamps")
        #expect(TrackerDiagnostics.tokenSummary(MetadataOnlyTokens(expiresIn: .infinity)) == "invalid credential timestamps")
    }

    @Test func `merge diagnostics distinguish direction and deletion without describing payloads`() {
        let secret = "secret-access-and-refresh-tokens"
        let cases: [(MergeVerdict<String>, String?)] = [
            (.noChange, nil),
            (.pushToCloud(secret), "write cloud credentials"),
            (.pushToCloud(nil), "remove cloud credentials"),
            (.pullToLocal(secret), "adopt cloud credentials"),
            (.pullToLocal(nil), "remove local credentials from cloud decision"),
            (.writeBoth(secret), "resolve credential conflict on both sides")
        ]
        for (verdict, expected) in cases {
            #expect(TrackerDiagnostics.mergeAction(verdict) == expected)
            #expect(TrackerDiagnostics.mergeAction(verdict)?.contains(secret) != true)
        }
    }
}

/// Even reading credential strings is unnecessary for a diagnostic summary.
private nonisolated struct MetadataOnlyTokens: TrackerTokens {
    var issuedAt: TimeInterval = 0
    var expiresIn: TimeInterval = 604_800
    var needsRefresh = true

    var accessToken: String {
        Issue.record("diagnostics read the access token")
        return "secret-access"
    }

    var refreshToken: String {
        Issue.record("diagnostics read the refresh token")
        return "secret-refresh"
    }
}
