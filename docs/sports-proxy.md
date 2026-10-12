# Optional proxy-assisted sports matching

Lume can consume the gateway's football broadcast publications through the
shared `SportsChannelResolver`. Home, Sports, competition lists and fixture
details retain the same resolver interface and channel-selection UI. The app
still fetches its own fixtures; it does not replace that feed with the proxy's
fixture-discovery endpoint.

## Negotiation and identity

Sports is independent of title metadata. `/lume/v1/capabilities` must advertise
the v1 sports contract, matcher v3, `source=espn`, the `broadcasts` group, a
positive batch limit and the requested competition. Unknown versions fall
back instead of guessing their matching semantics.

Only two-team `espn:soccer/*` fixtures with numeric ESPN event IDs participate.
Requests use the originating Xtream playlist's base path, query and account,
via `/lume/v1/sports/broadcasts?competition=…&ids=…`. IDs are deduplicated,
sorted and split at the smaller of the advertised limit and 50. UFC, F1,
tennis and other sports keep their local matching.

A response must be ready and unexpired, have a non-future validation time and
at most a 24-hour freshness interval. Source, competition, event ID, home and
away team IDs and kickoff must agree with the app's fixture, which must lie
inside the publication window. Duplicate event IDs are rejected; a malformed
item does not discard valid siblings. RFC3339 dates with or without fractional
seconds are accepted.

## Resolution and fallback

Provider stream IDs are mapped **only inside the responding playlist**. They
are never matched to another playlist by name or EPG ID. The current local
channel name, EPG ID and category must still agree. The normal visible-channel
query applies hidden channels and the viewer's category restrictions first.
An account edit during a request invalidates that account's response.

For each fixture and playlist:

| Proxy answer | App action |
| --- | --- |
| Fresh, valid, non-truncated, with visible timed candidates | Use those candidates instead of locally matching this playlist's guide |
| Untimed channel-name candidates only | Offer suggestions **and** run local matching; suggestions alone never enable one-tap playback |
| Unsupported, pending, failed, stale, malformed, empty, truncated, or filtered to no timed candidates | Run the existing local matcher |
| Other playlists | Resolve independently, using their own proxy or local guide |

Guide scans omit a playlist only when its relevant fixtures are covered. The
initial visible-channel snapshot is still read locally: this slice reduces
guide materialization and matching, not every SwiftData read.

Remembered picks still rank first, including picks absent from the proxy's
candidates. Candidates are deduplicated, ranked and assigned confidence again
on-device after merging with other playlists. Language/quality preferences and
playback selection remain unchanged. Raw evidence text is deliberately not
copied into programme titles, picker rows or player metadata: it can contain
scores, and must not bypass Hide Scores.

## Caching and request cost

The existing shared capability cache is reused. Sports reads coalesce identical
in-flight batches; their process-local cache is bounded to 16 batches and a
16 MiB input-byte budget. Ready responses are reused for at most 60 seconds,
never past publication expiry. Pending/failures retry after 10 seconds. Requests
have a 3-second request / 5-second resource timeout. An endpoint/network failure
also cools down its source for 10 seconds across batches and surfaces, so an
outage cannot charge one timeout per batch before local matching starts.
No authenticated URLs or
free-form evidence are logged or persisted by the sports client.

The resolver's ten-minute cache also keys each fixture by its proxy evidence.
Newly ready, changed or expired responses cannot be hidden by an older local
resolution. Playlist account identity is included in catalog cache invalidation.
The optional request may add latency on an uncached provider/outage; it cannot
disable local matching. At most four playlist negotiations run concurrently.

## Verification

`LumeProxySportsCapabilityTests`, `LumeSportsClientTests` and
`SportsProxyResolverTests` cover negotiation, batching, freshness, malformed
items, fixture identity, account-scoped URLs, cancellation, collisions between
playlists, restrictions, fallback, picks and confidence. Existing resolver and
capability suites remain regression coverage. Run these on an iOS 26.4+
simulator, not macOS or tvOS, with the shared SPM clone documented in AGENTS.md.

For a household check, enable football competitions on the proxy and open a
fixture with published evidence. Its access log should show authenticated
`/lume/v1/sports/broadcasts` reads. The app logs a `Sports proxy:` summary of
fixtures with timed matches and visible candidates on uncached resolves.
Confirm channel choices, then hide/restrict a
channel and check it disappears. Stop the proxy (or disable sports), allow the
60-second sports cache to expire, and reopen:
the original local resolver must remain usable. Empty proxy candidates are not
an authoritative “Not in your channels”. API correctness tests do not establish
real-world broadcast precision; review the actual candidates before release.

The proxy contract and matching policy live in the proxy repository's
`docs/sports-api.md` and `docs/sports-matching.md`. No provider credentials or
household channel fixtures belong in this document or the test data.
