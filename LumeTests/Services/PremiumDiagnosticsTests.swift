import Foundation
@testable import Lume
import StoreKit
import Testing

@MainActor
struct PremiumDiagnosticsTests {
    @Test(arguments: [
        VerificationResult<Transaction>.VerificationError.revokedCertificate,
        .invalidCertificateChain, .invalidDeviceVerification, .invalidEncoding, .invalidSignature, .missingRequiredProperties
    ])
    func `verification failures have explicit payload free names`(error: VerificationResult<Transaction>.VerificationError) {
        #expect(!PremiumDiagnostics.verificationFailure(error).isEmpty)
        #expect(!PremiumDiagnostics.verificationFailure(error).contains("unrecognized"))
    }

    @Test func `lifetime metadata records a non expiring Xcode entitlement`() {
        let summary = PremiumDiagnostics.metadata(
            productID: PremiumManager.Plan.lifetime.rawValue, environment: .xcode,
            revoked: false, expirationDate: nil, upgraded: false
        )
        #expect(summary == "plan=lifetime, environment=Xcode, revoked=false, expires=none, expired=false, upgraded=false")
    }

    @Test func `monthly metadata distinguishes active expired revoked and upgraded states`() {
        let expiry = Date(timeIntervalSince1970: 100)
        for expired in [false, true] {
            let summary = PremiumDiagnostics.metadata(
                productID: PremiumManager.Plan.monthly.rawValue, environment: .sandbox,
                revoked: false, expirationDate: expiry, upgraded: false,
                now: Date(timeIntervalSince1970: expired ? 101 : 99)
            )
            #expect(summary.contains("plan=monthly, environment=sandbox"))
            #expect(summary.contains("expires=1970-01-01T00:01:40Z, expired=\(expired)"))
        }
        let revoked = PremiumDiagnostics.metadata(
            productID: PremiumManager.Plan.monthly.rawValue, environment: .production,
            revoked: true, expirationDate: expiry, upgraded: true
        )
        #expect(revoked.contains("revoked=true"))
        #expect(revoked.contains("upgraded=true"))
    }

    @Test func `unknown metadata cannot smuggle account details into logs`() {
        let summary = PremiumDiagnostics.metadata(
            productID: "private-account-token", environment: .init(rawValue: "private-receipt"),
            revoked: false, expirationDate: nil, upgraded: false
        )
        #expect(summary.contains("plan=unrecognized, environment=unrecognized"))
        #expect(!summary.contains("private-"))
    }
}
