# Shared tracker authorization diagnostics

Trakt and Simkl authorization is shared through the encrypted CloudKit mirror.
A sign-in is not required on each device. These diagnostics do not change token
refresh, revocation, credential merge decisions, import gates or pending writes.

## Capturing a failure

Use the app's diagnostic export, or filter Console to subsystem
`com.leekiernan.lume`, categories `Network` and `CloudSync`. Capture launch through
an attempt to **Import Watched**. If pending changes block it, also capture
**Retry Pending Changes**. Keep the queue: clearing it would lose unsent intent.

When another device was recently used, its logs over the same period are useful.
The credential issue and expiry times can be compared without exposing tokens;
matching times alone do not prove two devices hold identical credentials.

## What the messages mean

- **Restore: initial / unchanged / replacement credentials** records what the
  process loaded, with UTC issue/expiry times and whether refresh is due.
  "Connected" still means credentials are held, not that the server accepted them.
- **Token refresh started / succeeded / rejected / unavailable** separates the
  local expiry decision from the server result. A rejection retains the pair and
  waits for a replacement rather than propagating a disconnect through iCloud.
  Backend failures include HTTP status or the sanitized transport error.
- **Account verification failed** records errors previously swallowed while
  restoring the account name. It does not clear the remembered identity.
- **Credentials saved locally** means a successful save notified the sync
  coordinator, not that CloudKit has completed an upload. Save failure is logged
  separately. **Credential merge** records direction, deletion/conflict decisions,
  and applied/pending counts; an unchanged merge stays quiet.
- **Credentials changed through iCloud** precedes restoring the in-memory
  session after a cloud pull, including removal.
- **Explicit disconnect requested** identifies a local user disconnect path.
  **Refresh result discarded** reports session replacement, pair replacement and
  cancellation separately. If that path revokes the discarded result, it says
  so. A successful revocation request does not establish the provider's wider
  effect on the authorization grant.
- **History import failed** now distinguishes no usable token from a failed
  request (HTTP 401, 429, decoding, transport, etc.). A deferred import records
  the pending count: local writes must upload before remote history is applied.
- **Watchlist request failed; keeping cached entries** distinguishes stale local
  content from a successful authenticated read. Trakt watchlist failures and
  mutation failures also report explicit error descriptions.

Simkl additionally logs allowlisted API/OAuth error identifiers, distinguishing
`invalid_token`, `user_token_required`, `invalid_grant`, `invalid_client` and
`insufficient_scope`. Unknown identifiers are recorded as `unrecognized`.

## Privacy and limits

No credential fingerprints, tokens, account/profile identifiers, device codes,
request URLs or response bodies are added to the logs. Token diagnostics read
only timing fields. Generic errors use the existing redaction helper; provider
errors use explicit descriptions. Tests cover redaction, allowlisting, missing
tokens, failed requests and unchanged shared-session behavior.

This is an observation pass, not an authentication fix. It does not add refresh
on HTTP 401 or additional retries. Collect the refresh and cloud-merge sequence
before choosing a recovery policy: the visible import failure alone cannot
establish expiry, revocation or another device replacing a shared token.
