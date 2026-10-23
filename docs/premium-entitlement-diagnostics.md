# Recorded purchases without Pro access

The iPhone's Xcode transaction manager shows Lifetime and Monthly purchases as
Purchased, while Lume remains on the free plan. The monthly expiry shown there
is in the future. Later purchase attempts fail with StoreKit's opaque
`ASDServerErrorDomain 2010`, environment Xcode; those later failures do not explain
what happened to the earlier recorded transactions.

The product IDs in `Lume.storekit` match `PremiumManager.Plan`. All feature gates
use the shared `PremiumManager.isPremium`. No duplicate manager instance or
different feature-specific Pro flag was found. This does not prove StoreKit
returns verified current entitlements to the running app.

## Evidence to capture

Build the diagnostic branch in Release, with `Lume.storekit` active. Keep the
existing transactions; do not reset, refund, delete or repurchase them. Capture
launch, then one Restore attempt, filtering app logs to category `Premium`.

The diagnostics record:

- Product discovery count and any missing products.
- Purchase outcomes: returned transaction, pending, cancelled or thrown error.
- Transaction verification result and its explicit failure category, without
  logging the signed payload, receipt, transaction IDs or account identifiers.
- Allowlisted plan/environment and expiry, revocation and upgrade metadata.
  Metadata from an unverified transaction remains untrusted; it grants nothing.
- Entitlement read sequence numbers, item counts and resulting ownership/Pro
  state. Sequence numbers expose overlapping reads; they do not change their
  ordering or authority.
- Transaction updates, including unverified updates previously finished silently.
- Restore's `AppStore.sync()` success or sanitized failure (previously discarded),
  followed by the entitlement read. Three bounded, read-only `latest(for:)`
  lookups then report whether StoreKit exposes history for each known plan,
  including the retired plan. These lookups do not grant access or mutate any
  transaction, but can lengthen a diagnostic Restore while awaiting StoreKit.

## Interpreting the result

- **Latest transaction exists, current entitlement absent:** inspect its
  verification, expiry, revocation and upgrade state. A Purchased row in Xcode's
  transaction manager alone does not establish a verified current entitlement.
- **Current entitlement unverified:** the verification category identifies why
  Lume did not accept it. Do not bypass verification to make the test pass.
- **Verified current entitlement applied with Pro=true, later Pro=false:** use
  read sequence numbers to determine whether another read replaced the state.
- **No current or latest transaction:** the running app's StoreKit view differs
  from the transaction manager's selected device/app view; compare that context
  before resetting anything.

The instrumented code preserves the existing grant rules, purchase/finish order,
transaction listener and checkout machine. Restore still refreshes entitlements
after a sync error. No household Premium override is introduced by this change.
