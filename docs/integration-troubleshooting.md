# Household builds and shared authorization

For an optimized household build that uses iCloud, run the **Release**
configuration with **Debug executable** unchecked. The **Sideload** configuration
unlocks Pro but also disables CloudKit in `LumeApp`; it cannot distribute refreshed
tracker credentials between devices. Reconcile messages alone do not establish
that the mirror is connected to CloudKit.

Trakt and Simkl authorization is shared through the encrypted CloudKit mirror.
The October 2026 investigation found devices holding different credential
generations while running Sideload. After switching to Release, CloudKit pulled
replacement credentials and tracker imports succeeded without reconnecting.

For local StoreKit testing, select `Lume.storekit` in the scheme's Run options.
These test purchases are separate from shared tracker authorization. A subsequent
iPhone launch returned a verified lifetime entitlement and enabled Pro; the
earlier failure to recognize recorded purchases was not reproduced or explained.
The temporary entitlement probes did not change access rules.

## Investigating import failures

Export diagnostics or filter Console to subsystem `com.leekiernan.lume`, category
`Network`. Capture launch and an **Import Watched** attempt. If pending changes
block it, capture **Retry Pending Changes** too; keep the queue to preserve unsent
intent. Provider errors distinguish authentication, HTTP status, decoding and
transport failures. Import failures distinguish a missing usable access token
from a failed request. Watchlist failures retain their cached entries.

Confirm CloudKit is enabled before changing authorization. A rejected token alone
does not establish whether it expired, was revoked or was replaced on another
device. Do not log credentials, signed purchase payloads or raw response bodies.
