import Foundation
import StoreKit

/// Describe only the fields needed to investigate entitlement delivery. Never
/// interpolate a Transaction, receipt, JWS, account token or transaction ID.
enum PremiumDiagnostics {
    static func verificationFailure(_ error: VerificationResult<Transaction>.VerificationError) -> String {
        switch error {
        case .revokedCertificate: "revoked certificate"
        case .invalidCertificateChain: "invalid certificate chain"
        case .invalidDeviceVerification: "invalid device verification"
        case .invalidEncoding: "invalid encoding"
        case .invalidSignature: "invalid signature"
        case .missingRequiredProperties: "missing required properties"
        @unknown default: "unrecognized verification failure"
        }
    }

    static func transaction(_ result: VerificationResult<Transaction>) -> String {
        let transaction: Transaction
        let verification: String
        switch result {
        case let .verified(value):
            transaction = value
            verification = "verified"
        case let .unverified(value, error):
            transaction = value
            verification = "unverified (\(verificationFailure(error)))"
        }
        let details = metadata(
            productID: transaction.productID, environment: transaction.environment,
            revoked: transaction.revocationDate != nil, expirationDate: transaction.expirationDate, upgraded: transaction.isUpgraded
        )
        return "\(verification); \(details)"
    }

    static func metadata(
        productID: String, environment: AppStore.Environment, revoked: Bool,
        expirationDate: Date?, upgraded: Bool, now: Date = .now
    ) -> String {
        let product = switch PremiumManager.Plan(rawValue: productID) {
        case .monthly: "monthly"
        case .lifetime: "lifetime"
        case .retiredMonthly: "retired monthly"
        case nil: "unrecognized"
        }
        let source = switch environment {
        case .xcode: "Xcode"
        case .sandbox: "sandbox"
        case .production: "production"
        default: "unrecognized"
        }
        let expiry = expirationDate?.ISO8601Format() ?? "none"
        return "plan=\(product), environment=\(source), revoked=\(revoked), expires=\(expiry), expired=\(expirationDate.map { $0 <= now } ?? false), upgraded=\(upgraded)"
    }
}
