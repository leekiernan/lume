import Foundation

/// Explicit allowlist for shared-auth diagnostics. Never format a credential
/// model or merge verdict directly: both contain access and refresh tokens.
nonisolated enum TrackerDiagnostics {
    /// Provider error identifiers are useful; arbitrary response prose is not
    /// safe to log, even when the provider calls it an error identifier.
    static func simklErrorCode(_ raw: String?) -> String {
        switch raw {
        case "invalid_token", "user_token_failed", "user_token_required", "invalid_client", "invalid_grant",
             "invalid_request", "invalid_scope", "unsupported_grant_type", "authorization_pending", "slow_down",
             "expired_token", "insufficient_scope", "oauth2_token_required", "client_id_failed": raw ?? "unrecognized"
        default: "unrecognized"
        }
    }

    static func tokenSummary(_ tokens: some TrackerTokens) -> String {
        let expiry = tokens.issuedAt + tokens.expiresIn
        guard tokens.issuedAt.isFinite, expiry.isFinite else { return "invalid credential timestamps" }
        let issued = Date(timeIntervalSince1970: tokens.issuedAt).ISO8601Format()
        let expires = Date(timeIntervalSince1970: expiry).ISO8601Format()
        return "issued=\(issued), expires=\(expires), refreshDue=\(tokens.needsRefresh)"
    }

    /// Only changed merges are logged; polling/reconcile no-ops stay quiet.
    static func mergeAction(_ verdict: MergeVerdict<some Equatable>) -> String? {
        switch verdict {
        case .noChange: nil
        case .pushToCloud(nil): "remove cloud credentials"
        case .pushToCloud: "write cloud credentials"
        case .pullToLocal(nil): "remove local credentials from cloud decision"
        case .pullToLocal: "adopt cloud credentials"
        case .writeBoth: "resolve credential conflict on both sides"
        }
    }
}
