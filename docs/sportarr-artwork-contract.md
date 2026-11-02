# Optional sports artwork: app contract

App implementation in `feat/sportarr-artwork-enrichment`, begun 2026-11-01.
Endpoint, capability and publication fields checked against the sibling proxy's
`feat/sportarr-artwork` implementation on 2026-11-02. Both sides use `matched`
statuses, `poster`, `thumb` and `fanart` image fields, and the ESPN fixture
identity that justified each match. App tests use mocked responses; deployment
and real-device coverage checks remain separate.

## Negotiation and requests

Independently advertise the following at the existing authenticated
`/lume/v1/capabilities` endpoint (also under configured base paths):

```json
{
  "v": 1,
  "sports_artwork": {
    "v": 1,
    "matcher_v": 1,
    "source": "espn",
    "artwork_source": "sportarr",
    "competitions": ["soccer/eng.1"],
    "max_batch_size": 50
  }
}
```

The app requests `GET /lume/v1/sports/artwork?competition=soccer%2Feng.1&ids=401,402`
with the existing proxy account query parameters. IDs are deduplicated and
sorted, and batches contain at most 50 IDs (or the advertised smaller limit).
Only explicitly advertised football competitions with two known ESPN teams
are eligible in this first slice. The proxy maps the requested fixtures into
its cached league/date windows; this must not trigger per-event upstream detail
lookups. Neither a broadcast capability nor a broadcast matcher version enables
artwork on its own.

## Response

```json
{
  "v": 1,
  "matcher_v": 1,
  "source": "espn",
  "artwork_source": "sportarr",
  "competition": "soccer/eng.1",
  "status": "ready",
  "verified_at": "2026-11-01T12:00:00Z",
  "expires_at": "2026-11-01T18:00:00Z",
  "from": "2026-11-01T00:00:00Z",
  "to": "2026-11-02T00:00:00Z",
  "items": [{
    "event_id": "401",
    "status": "matched",
    "fixture": {
      "source": "espn",
      "competition": "soccer/eng.1",
      "event_id": "401",
      "start": "2026-11-01T15:00:00Z",
      "home": {"id": "1"},
      "away": {"id": "2"}
    },
    "artwork": {
      "poster": "https://sportarr.net/static/images/event/example/poster.jpg?v=1",
      "thumb": "https://sportarr.net/static/images/event/example/thumb.jpg?v=1"
    }
  }]
}
```

Examples are synthetic. The app ignores unknown fields. It does not decode
scores, descriptions, result status, captions, broadcaster text or alternate
titles. `source_id` may be present for proxy diagnostics but does not replace
ESPN identity. An explicit unmatched/ambiguous item carrying a valid fixture
identity retracts previously cached artwork for that fixture. Malformed and
duplicate event items yield no update. A ready response may contain no matches.
Missing/pending/unavailable publications and non-200 responses preserve existing
presentation.

The app accepts envelope and artwork matcher version 1 only. Timestamps must
be valid, verification cannot be in the future, expiry must be after now and
verification, and the verification-to-expiry interval cannot exceed 24 hours.
Kickoff must be within `[from, to)` and agree with the current ESPN fixture to
within one second. Competition, event ID and ordered home/away ESPN team IDs
must agree exactly. This catches rescheduling and stale cached mappings without
changing follows, reminders or channel picks.

## Bounds, images and presentation

- Bodies are limited to 256 KiB before allocation; at most 50 response items.
- One refresh reads at most eight batches per source and four playlist sources.
  Transport timeouts are 3 seconds/request and 5 seconds/resource. There are at
  most four distinct in-flight artwork requests and two connections per host.
- Concurrent identical requests coalesce. At most 16 decoded batches are kept
  for five minutes or publication expiry, whichever comes first. Failed reads
  back off for 30 seconds per account. Unsupported capability probes reuse the
  existing capability cache and make no artwork request.
- A bounded, shared in-memory presentation cache holds at most 256 event
  publications, retaining their original expiry even when read again. It is
  derived public data; no authenticated URL or account token is persisted.
  No additional disk metadata cache is introduced in this slice. Existing
  image-byte caching and TheSportsDB fallback caches remain in use.
  Explicit no-artwork publications replace old matches; transient failures
  retain the previous image only until its original expiry.
- Only HTTPS Sportarr `/static/images/event/` URLs (optional `v` query) and
  TheSportsDB `/images/media/event/` URLs (no query) are accepted, without user
  information, ports, fragments or escaped/traversal paths. No provider or
  tracker credentials accompany image requests.
  The optional version is a single nonempty ASCII alphanumeric/dash/underscore
  value of at most 80 characters, not another URL or a credential parameter.
- Phone portrait heroes prefer an event poster; other backdrops prefer fanart,
  then the event thumbnail. Existing team/league/sport artwork remains the
  fallback, including after an enriched image fails. Sportarr images do not
  receive TheSportsDB's `/medium` suffix.
- Artwork refresh runs alongside channel resolution on a background executor.
  It adds no SwiftData writes, view-body SQL or prerequisite for rendering,
  channel publication or playback. Results from an edited/removed proxy account
  or a cancelled selection are discarded. Current fixture identity is checked
  again whenever a backdrop reads cached artwork.

The shared `SportsArtworkBackdrop` covers hub heroes and artwork highlight
cards on all platforms. Existing Home fixture logo cards and detail team logos
keep their current layouts. This change does not introduce new image placements.

Shipping also requires proxy coverage/cost measurements and the hosted-data
reuse decision in [the enrichment plan](sportarr-enrichment-plan.md).
