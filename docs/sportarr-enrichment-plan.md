# Sportarr enrichment for the Sports Hub

Written 2026-11-01. Proposal only: no Sportarr integration, proxy endpoint or
provider migration is implemented by this note.

## Recommendation

Use Sportarr as optional artwork and metadata enrichment. Keep ESPN as the
source of fixtures, live scores and match detail initially. Prefer shared
proxy caching for a lasting integration; a direct, bounded probe is sufficient
to establish whether coverage warrants implementing it.

The proxy is an optional, separately deployed service, not a central cache
shared by every Lume installation. It can share work among devices using that
instance. Standalone clients retain today's ESPN/TheSportsDB behaviour.

## Evidence and limits

Sportarr exposes a hosted metadata service independently of its self-hosted PVR
application. Users would not need to install the PVR. Primary references:

- [Metadata API explorer](https://wiki.sportarr.net/api-explorer/)
- [Live OpenAPI specification](https://sportarr.net/openapi.json)
- [External ID contract](https://wiki.sportarr.net/EXTERNAL_IDS/)

The inspected specification describes unauthenticated reads under
`/api/public/v1`, with per-IP limits of 120 requests/minute and 2,000/hour,
and authenticated access with higher limits. These are observed service terms,
not a capacity guarantee; recheck before implementation. It exposes sports,
leagues, teams, people, venues, date-filtered events and artwork. TV-listing
and live-score compatibility endpoints also exist, but their usefulness and
freshness were not validated.

Read-only API samples on 2026-11-01:

| Sample | Observed artwork URLs |
| --- | --- |
| 25 Premier League events, 2026-10-25 through 2026-11-08 | 25 posters, 25 thumbnails, 13 banners, no fanart |
| Seven UFC events, 2026-10-01 through 2026-11-01 | Six posters, seven thumbnails, five backdrops |
| Three UFC events, 2026-11-01 through 2026-12-01 | No event artwork |

Two sampled image URLs returned HTTP 200 with JPEG content types. Counts above
describe populated URL fields, not a check of every image or general coverage.
The sports endpoint returned 37 categories; this does not establish complete
fixture coverage or that those categories belong in our UI.

Sampled image metadata identified TheSportsDB as its source. Sportarr's value
may be aggregation, caching and convenient event-level discovery rather than
additional artwork unavailable from our existing source. Compare against
Lume's actual fallback output before claiming an improvement.

Matching cannot use the first search result: a search for "English Premier"
returned the women's competition before the men's. Sampled league records
exposed TheSportsDB IDs (`4328` for the Premier League, `4443` for UFC), while
sampled event records had null `tsdbId` values. Slugs were also null; use
discovered canonical IDs rather than guessing URLs from league names.

No clear hosted-data/artwork reuse terms for a commercial app were found in
this investigation. Clarify permitted use, caching and attribution before
shipping; the PVR application's source-code licence does not resolve that
question.

## Responsibility split

| Responsibility | Owner | Reason |
| --- | --- | --- |
| Sportarr lookups and artwork URL discovery | Proxy, when supported | Cache once per instance; coalesce requests and coordinate upstream pacing |
| Sportarr-to-ESPN identity mappings | Proxy; app validates returned identity | Fix mappings without a client release; preserve existing fixture IDs |
| Image downloads and decoded/disk image cache | App, directly from approved image hosts | Reuse the image pipeline without adding proxy bandwidth/storage work |
| ESPN fixtures, live scores and match detail | App initially | Avoid a broader feed migration and new score freshness responsibilities |
| Visibility restrictions, channel ranking and playback choice | App | Depend on the device's playlists, profile and current catalogue |

The existing proxy already fetches a bounded football schedule for its
broadcast matcher. That does not make it a replacement for the app's sports
feed. See [the current app contract](sports-proxy.md) and the proxy's
`docs/sports-api.md` in the sibling `proxy` checkout. Some proxy documentation
still says the app does not consume broadcasts; the app integration now does.

`SportsDataProvider` is a useful seam, but this is not a drop-in provider swap:
`SportsLeague.makeID` still constructs ESPN identities, and artwork lookup is
separate in `SportsArtwork`. Preserve follows, reminders, channel picks and
fixture identities; enrich existing records rather than creating duplicates.

## Smallest useful implementation

Start with event artwork for a small, explicitly mapped set of followed leagues.
Fetch date windows in batches, not one remote lookup per visible card. Do not
crawl the entire sports catalogue or add categories, schedules or broadcast
sources as part of this first slice.

On the proxy:

- Negotiate enrichment as an optional capability, separate from existing
  broadcast matching. No route/schema is committed by this proposal.
- Share public enrichment independently of playlist accounts. Cache keys include
  upstream source, canonical league ID, date window and any language/variant
  parameters; derived matches also depend on fixture identity and mapping
  version. Keep account-specific broadcast candidates in their existing scope.
- Refresh in the background with bounded pagination, response sizes, concurrency,
  retention and request coalescing. Pace requests across the instance, honour
  upstream retry guidance and cache misses briefly. A forwarding-only endpoint
  concentrates per-IP traffic without saving upstream calls.
- Serve cached publications immediately with freshness metadata and validators.
  A miss is pending/unavailable; a read must not wait for upstream enrichment.
  Permit bounded stale artwork, without renewing its age on failed refreshes.
- Return source identity, the matched ESPN fixture identity and artwork URLs.
  Validate league, participants and date/time; abstain on ambiguity. Rescheduled
  fixtures invalidate old matches. Never infer playback permission from artwork.

On the app:

- Render from the existing sports cache immediately. Load optional enrichment
  asynchronously and request image bytes only for surfaces that need them.
- Validate responses against the current fixture and selection before applying.
  Use the shared artwork path across Home, Sports and detail surfaces.
- Retain current fallbacks for misses, unsupported proxies and outages. Do not
  add a serial "proxy timeout, then direct Sportarr timeout" path or make every
  proxy miss trigger an uncached direct lookup on each device.
- Use bounded, credential-free URL handling. Send no tracker credentials,
  playlist credentials or watch history to Sportarr. An image proxy accepting
  arbitrary caller-provided URLs is outside this scope.

## Validation and expansion gates

1. Compare the same fixtures with today's artwork and with enrichment. Record
   new usable images, duplicates, missing/broken URLs and wrong-event matches;
   exercise women's/youth distinctions, same-day rematches and rescheduling.
   Ambiguous fixtures must retain their fallback, not receive a guessed image.
2. Record cold/warm time to first usable Sports content and main-thread stalls
   on Apple TV. Enrichment must not gate rendering or introduce synchronous
   network/database work in view evaluation. Confirm remote responsiveness.
3. Open the same league/window on two clients concurrently. Verify one shared
   upstream fetch per page, cache reuse on repeat reads and bounded storage.
4. Exercise 429, timeout, malformed/oversized responses, missing artwork,
   unsupported capability and proxy outage. Existing content remains usable;
   retries stay bounded and failures do not refresh stale-data timestamps.
5. Keep raw source payloads behind adapters and test the matching/publication
   contract. No follow/profile migration should be necessary for enrichment.

Expand only if the trial demonstrates useful additional artwork at an acceptable
request cost. Broader discovery, TV listings, shared ESPN feeds and proxy image
delivery need their own coverage, freshness and cost evidence. Do not move them
merely because the proxy can make HTTP requests.

## Verification (2026-11-01)

The claims above were rechecked against the live service, Sportarr's client
source (`Sportarr/Sportarr`, `src/Services/SportarrApiClient.cs`) and both
codebases. Context since writing: the proxy's cache is the intended path, and
this household's proxy is currently its only user.

### Confirmed

- OpenAPI specification `Sportarr-Hub API` 1.8.0: `/api/public/v1` needs no
  key and is limited per IP to 120 requests/minute and 2,000/hour. It carries
  no `termsOfService` or `license`, so the reuse question stays open.
- A search for "English Premier" ranks *English Premier Womens League* above
  *English Premier League*. Abstaining on ambiguity is required, not optional.
- The `/api/public/v1/events` listing returns null `tsdbId` (25 of 25 in the
  Premier League window), and its records have no slug field at all. Artwork
  counts match the sample table: 25
  posters, 25 thumbnails, 14 banners (13 when first sampled: the data moves),
  no fanart.
- Image filenames carry their provenance (`badge_thesportsdb_…`), so the
  artwork is TheSportsDB's. It is served from Cloudflare with
  `cache-control: public, max-age=31536000, immutable`, which suits the plan
  of the app fetching image bytes directly.
- `SportsDataProvider` is the seam, and `SportsLeague.makeID` hard-codes
  `espn:{sport}/{slug}`: enrichment must attach to ESPN ids, not replace them.
- The proxy stores schedules per source, competition and date window
  (`internal/sports/schedules.go`), so its existing fetch is bounded.
- The proxy's `docs/sports-api.md` (line 3) still says the app does not
  consume broadcasts. It is stale; the app does.
- Every figure in [sports-proxy.md](sports-proxy.md) matches the code: 16
  batches and 16 MiB cached, 60 s ready / 10 s pending reuse, 3 s / 5 s
  timeouts, a 10 s cooldown, unavailable negotiations cached for 60 s, batches
  capped at 50, four concurrent playlist negotiations and a ten-minute resolver
  cache. Undocumented there: a single response is capped at 8 MiB
  (`LumeSportsClient.maximumBytes`).

### Corrections and additions

- **The TheSportsDB id is only missing from the listing.** The same game
  (`ev-2301184`, Liverpool v Arsenal) has `tsdbId` `2494082` on both the public
  event detail (`/api/public/v1/events/{id}`) and the TheSportsDB-compatible
  lookup. The specification publishes 32 such `/api/v2/json/*` routes (lookup,
  search, `list/teams`, `schedule/league/{id}/{season}`,
  `list/seasonposters`, `tv`, `livescore`); Sportarr's own client uses them.
  Teams there carry a TheSportsDB id, a short code (`ARS`) and club colours.
  This narrows the identity gap without closing it: no record carries an ESPN
  id, so matching Sportarr events to ESPN fixtures by league, date and
  participants is still required. Don't mandate per-event detail or
  compatibility lookups until their batch coverage and request cost have been
  compared with the listing's.
- **Stable ids for every entity.** Leagues `lg-`, teams `tm-` and events `ev-`
  short ids, documented as permanent and never reused
  (`docs/EXTERNAL_IDS.md`), alongside a UUID. Key the proxy's mappings on short
  ids.
- **More event artwork than the table lists.** Every sampled Premier League
  event also carries its league badge and both teams' badges, and 14 of 25
  carry a square image. The UFC samples have no team badges. `thumbUrl` is the game's own 16:9 image: the wide heroes and big
  cards currently use one team's generic fanart (`SportsArtwork.art`).
- **Matching data.** Events carry an alternate title (`Arsenal @ Liverpool`),
  round, season, venue, a UTC start and a `broadcastDate` in the league's
  `broadcastTimezone` (`Europe/London`). Teams carry short codes. These are
  candidate aliases for the guide matcher, outside the first artwork slice.
- **TV listings are populated per event, without times.** `tv/event/ev-2301184`
  returned 37 broadcasters across 30 countries, including UK *Sky Sports
  Premier League* and *Sky Sports Main Event*, every `broadcastTime` null.
  `tv/date/2026-11-01` returned no rows. Broadcaster names may only add or
  rank candidates in the existing guide matching, never restrict which
  channels it searches: listings can be incomplete, and a narrowed search
  would drop valid local matches. A broadcaster is not a playlist channel, so
  a hint alone is never a playable match. This is a later gate, after
  artwork.
- **Public events carry live scores, and outcomes can hide in text.** The
  sampled game was `status: in_progress` at 0–1. Dropping score and status
  fields is not enough: descriptions, results text, video links and captions
  can reveal an outcome too. The initial adapter keeps an allowlist and drops
  everything else:
  - **Identity:** the event, league and team short ids and UUIDs, `tsdbId`,
    team names, scheduled start, `broadcastDate` and `broadcastTimezone`,
    round, season and venue name.
  - **Artwork:** `posterUrl`, `thumbUrl`, `bannerUrl`, `squareUrl`,
    `fanartUrl`, `leagueBadgeUrl`, `homeTeamBadgeUrl` and `awayTeamBadgeUrl`.

  Anything else (descriptions, alternate titles, broadcasters) needs its own
  spoiler review before it is added. ESPN stays the score source as planned.
- **A registered key is offered.** The specification describes `/api/v1` with
  an `X-API-Key` and higher limits "for registered consumers", and calls the
  public API "designed for Sportarr instances". Ask the maintainers for a key
  for the proxy; that conversation is also where the reuse terms get settled.
- **Pacing is already expected.** Sportarr's own client spaces its hub calls
  (`HubRequestPacer`) because the hub enforces a per-second allowance as well
  as the documented per-minute one. The proxy should do the same.

### What today's artwork path does, for the comparison gate

`SportsArtwork` uses TheSportsDB's free v1 key (`123`), paced to 30
requests/minute:

- **Team fanart:** found by name search (`searchteams.php`, first result with
  the right sport). That's fragile for name variants and duplicate club names.
- **League fanart and posters:** only for about 25 hard-coded competitions
  (`leagueIds`).
- **Event posters:** an event search by title and date, for the compact hero
  only.
- **Fallback:** a generic image per sport.

Compare enrichment against each of these on the same fixtures, as gate 1
describes.
