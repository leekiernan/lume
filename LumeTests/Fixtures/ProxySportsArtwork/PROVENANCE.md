# Proxy sports artwork contract fixtures

Exact serialized HTTP responses from the sibling proxy implementation at commit
`f6f1bc8` (`feat/sportarr-artwork`), captured on 2026-11-02. The app tests do not
construct or alter these JSON payloads.

A temporary Go test overlay called the proxy's real capability/artwork handlers
using its existing `prepareArtwork` harness and `sportsPass` worker. The checkout
was not modified. ESPN and Sportarr inputs were synthetic; no live upstream
calls, account tokens or real user data were involved. The proxy's sports and
Xtream integration suites also passed with the race detector.

| Fixture | Handler state |
| --- | --- |
| `capabilities-enabled` | Sports and independent artwork capability enabled |
| `capabilities-disabled` | Sports enabled, artwork disabled |
| `pending` | Before first worker publication; timestamps and fixture payloads omitted |
| `matched` | Matched event 401, image URL, and unavailable event 999 |
| `unmatched` | Successful empty Sportarr window; explicit unmatched fixture |
| `ambiguous` | Two matching Sportarr candidates; explicit ambiguous fixture |
| `matched-without-images` | Unique match with no images yet |
| `unavailable` | Expired publication retaining its original timestamp fields |
| `reference` | Captured clock after all responses; not an endpoint response |

All cases use the same ESPN kickoff and participants. `reference.json` lets the
Swift tests use the source clock, so these fixtures do not expire as time passes.
Nonready results must preserve existing fallbacks and avoid repeated requests;
explicit ready no-artwork results must retract old artwork.

To refresh, export the same states through the proxy's handlers, keeping ESPN
fixture identity constant across cases. Use a nonnil empty event slice for the
empty-window case, matching `Sportarr.FetchArtwork`. Capture a reference clock
after the final response. Copy the raw response bytes and run
`LumeSportsArtworkContractTests` alongside the proxy tests. Do not hand-edit the
JSON to make the app decoder pass.
