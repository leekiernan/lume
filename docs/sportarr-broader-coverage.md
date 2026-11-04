# Broader Sportarr artwork coverage

Assessed 2026-11-03 against app `b9218f65` and proxy `f6f1bc8`.
This is a measured expansion recommendation; no runtime coverage is enabled
by this document. The user reports the initial artwork working well on device.

Implementation of the first two steps is on `feat/sportarr-team-sports` in both
checkouts: the additional football mappings and guarded aliases, independently
configured NFL/NBA/NHL artwork, and padded discovery with original UTC filtering.
The v1 publication shape is preserved. Replay of these captured samples now
matches usable artwork for Bundesliga 9/9, Ligue 1 10/10 and MLS 18/18, plus
NFL 16/16, NBA 56/56 and NHL 52/52, without ambiguous matches. The tables below
retain the original measurements so the improvement remains reviewable.

Implementation validated on 2026-11-04: app `29a9fcfc`, proxy `08298e0` and
`1cc2c6a`. Both implementation branches remain unmerged pending user approval.
The full iOS Simulator unit suite passed (4,535 executions, one skipped),
including the focused artwork/contract regressions; the unsigned tvOS build,
Swift formatting/lint checks and full proxy `go test -race ./...` also passed.
App evidence: `/tmp/lume-team-sports-full.xcresult` and
`/tmp/lume-team-sports-targeted-current-sim.xcresult`.

Deployment remains opt-in: `SPORTS_ARTWORK=sportarr` enables the source;
`SPORTS_ARTWORK_COMPETITIONS` selects artwork independently. When omitted, it
inherits `SPORTS_COMPETITIONS`, preserving existing deployments. The new
registry entries alone do not enable additional competitions.

## Recommendation

Expand the existing football mapping first, and prepare a separate artwork-only
path for NFL, NBA and NHL. These have useful current coverage using the existing
two-team matcher. Keep ESPN fixture identities and the existing fallback chain.
F1 is the next distinct matching shape worth implementing. Combat, tennis and
cricket do not yet justify broadening matching or substituting schedules.

## How this was measured

Read the public [Sportarr schema](https://sportarr.net/openapi.json),
[sports catalogue](https://sportarr.net/api/public/v1/sports?page_size=100) and
[league directory](https://sportarr.net/api/v2/json/all/leagues), then sampled
27 competitions in Lume's existing catalogue. Canonical league IDs below came
from the directory, with sport/name/TheSportsDB identity checked; no first-result
search matching was used.

Captured public ESPN month scoreboards and Sportarr event pages into `/tmp`,
then passed those bytes through the proxy's actual `ParseESPN`,
`ParseSportarrEvents` and `MatchArtwork` functions using a temporary Go test
overlay. The proxy checkout was not modified. The probe passed. There are
36 observations, including date-boundary comparisons and six active-season
samples. The distilled counts and exact query dates are in
[the measurement CSV](data/sportarr-coverage-2026-11-03.csv).

The principal UTC window is **2026-11-02 inclusive through 2026-11-10 exclusive**.
All sampled Sportarr responses fit one page; a zero result is an observed empty
window, not a claim of permanent absence. Rows with parser errors are explicitly
marked in the CSV and must not be interpreted as zero source fixtures.

"Usable art" counts only a matched event with a validated poster, thumbnail or
fanart URL, which the app currently consumes. League/team badges, banners and
squares do not count. All sampled URL shapes in those three fields passed the
app's current restrictions. Four representative thumbnails (Serie A, NFL, NBA,
NHL) returned HTTP 200 with JPEG content types. The remaining image bytes were
not downloaded, so these are metadata/matching measurements, not a complete
image delivery test or a performance benchmark.

## Current-window results

The first eight rows used the original date query. US sports and MLS use the
padded query described below. No ambiguous matches were returned in these
samples; this does not independently prove matching precision. The non-exact
name matches were inspected, including Deportivo/Deportivo de La Coruña,
Athletic Club/Athletic Bilbao and LA Clippers/Los Angeles Clippers.

| Competition | Sportarr league | Matched / ESPN fixtures | Usable art | Posters | Landscape |
| --- | --- | ---: | ---: | ---: | ---: |
| Bundesliga | `lg-000004` | 8/9 | 8 | 8 | 8 |
| LaLiga | `lg-000007` | 11/11 | 11 | 8 | 11 |
| Serie A | `lg-000005` | 12/12 | 12 | 12 | 12 |
| Ligue 1 | `lg-000006` | 9/10 | 9 | 9 | 9 |
| Eredivisie | `lg-000009` | 9/9 | 9 | 0 | 9 |
| Primeira Liga | `lg-000013` | 11/11 | 11 | 0 | 11 |
| EFL League One | `lg-000036` | 3/3 | 3 | 0 | 3 |
| EFL League Two | `lg-000037` | 1/1 | 1 | 0 | 1 |
| NFL | `lg-000032` | 16/16 | 16 | 6 | 16 |
| NBA | `lg-000030` | 56/56 | 56 | 55 | 56 |
| NHL | `lg-000028` | 52/52 | 52 | 1 | 52 |
| MLS | `lg-000014` | 15/18 | 15 | 15 | 15 |

The EFL samples are small, during an FA Cup week. Treat them as positive checks,
not broad coverage estimates. Bundesliga's miss is FC Cologne versus Köln;
Ligue 1's is Paris Saint-Germain versus Paris SG. MLS misses include LAFC versus
Los Angeles FC and Red Bull New York versus New York Red Bulls. Fix these with
verified, competition-scoped identities/aliases and collision tests, rather
than allowing arbitrary acronym or word-order matching.

Landscape improvements are more widely available than portrait improvements.
The current app already falls back when a poster is absent; keep that behaviour.

## A prerequisite for US coverage: date boundaries

The public event query filters by the league's broadcast date in these samples.
For example, a late US game on November 1 can have a November 2 UTC kickoff;
querying `from=2026-11-02` omits it. At the other boundary, the query included
November 10 UTC games whose US broadcast date is November 9.

Using identical ESPN fixtures and matcher code:

| Competition | Original query matches | Padded query matches |
| --- | ---: | ---: |
| NFL | 15/16 | 16/16 |
| NBA | 54/56 | 56/56 |
| NHL | 51/52 | 52/52 |

For the logical window `[2026-11-02, 2026-11-10)`, query Sportarr dates
`2026-11-01` through `2026-11-10` inclusive, then filter by the original UTC
`scheduledStart` interval. Keep the cache/publication window equal to that
original interval and enforce the existing response/page bounds. This widens
discovery, not the fixture-match tolerance or publication eligibility.

The proxy currently uses `from.UTC().Date()` through `(to - 1ns).Date()`.
Padding belongs in its upstream query construction, with regressions for
positive and negative UTC offsets, DST, and both half-open endpoints. One matched
NHL fixture had a one-hour source time difference; keep ESPN's schedule and
require the returned publication to echo ESPN's kickoff as it does today.

Example source requests for this comparison:
[original NBA window](https://sportarr.net/api/public/v1/events?league=lg-000030&from=2026-11-02&to=2026-11-09&page_size=100&order=asc),
[padded NBA window](https://sportarr.net/api/public/v1/events?league=lg-000030&from=2026-11-01&to=2026-11-10&page_size=100&order=asc),
[ESPN November NBA scoreboard](https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates=202611&limit=1000).

## Other team sports and missing data

| Competition | Sample UTC window | Matched / fixtures | Usable art | Assessment |
| --- | --- | ---: | ---: | --- |
| MLB (`lg-000060`) | Oct 24–Nov 1 exclusive | 5/5 | 5 | Positive postseason sample; validate regular-season doubleheaders before enabling broadly |
| AFL (`lg-000092`) | Sep 14–22 exclusive | 2/2 | 2 | Positive finals sample; needs a wider active-season sample |
| WNBA (`lg-000151`) | Sep 14–22 exclusive | 14/16 | 10 | Matching does not imply an image; two source records have contradictory participant identities |
| United Rugby Championship (`lg-000082`) | Oct 23–31 exclusive | 9/10 | 9 | Promising; verify remaining team aliases |
| Top 14 (`lg-000066`) | Nov 2–10 exclusive | 3/8 | 3 | Needs team identity work and review of duplicate/inconsistent ESPN fixtures |
| NRL (`lg-000055`) | Sep 14–22 exclusive | 0/2 | 0 | ESPN uses nicknames; source uses full names, and neither side agrees under current rules |
| Women's Super League (`lg-000486`) | Nov 2–10 exclusive | 0/7 | 0 | No Sportarr events in this window |
| NWSL (`lg-000156`) | Nov 2–10 exclusive | 0/4 | 0 | Padded response has the preceding regular-season games, not ESPN's playoff fixtures |
| Sheffield Shield (`lg-001139`) | Nov 10–18 exclusive | 0/3 | 0 | No Sportarr events; multi-day match overlap also needs review before adding cricket |

English Prem Rugby (`lg-000053`) had no fixtures in the main window; that is
inconclusive. WNBA, MLB, NRL and AFL were also empty in the main window, which is
why the active-season checks above were necessary.

Examples that should remain unmatched: a WNBA record named Portland Fire versus
Phoenix Mercury has Portland Fire on both participant fields; another Portland
fixture has inconsistent participant data. Top 14 includes differently numbered
ESPN fixtures with opposite home/away orientation for Perpignan/Pau. Preserve
fallbacks instead of overriding those identities from an event title.

## Motorsport, combat and tennis

**F1 is worth a separate next slice.** The São Paulo weekend has five Sportarr
session records with event artwork. ESPN also has five sessions, with matching
start times and FP1/FP2/FP3/qualifying/race kinds in this sample. The current proxy
parser rejects the multi-session ESPN shape and drops Sportarr records without
two teams. The app uses one parent event ID plus session-specific local IDs and
start times, so merely removing `hasTeams` would invalidate identity checks or
apply one session's artwork to another. Match league + weekend/circuit + session
kind + start, echo the precise local session identity, and test sprint weekends,
changed timetables and repeated circuit names. Do not widen the existing team
contract until those identities are represented explicitly.

**UFC needs more than league/date proximity.** In the main window Sportarr has
one record, no usable event images, and no two-team fields. Its card title is
Bonfim versus Brady, while ESPN's is Cortes Acosta versus Walker, with a different
start time. These are not a verified pair. PFL had no card in this window.
Historic UFC poster counts in the original plan do not establish upcoming-card
coverage. Any later card matcher should use promotion, card identity/main event
and date, and keep a card distinct from its individual bouts.

**Tennis is not demonstrated yet.** Sportarr returned no ATP/WTA events for this
window. ESPN's feeds represent tournaments containing matches, rather than the
single competition assumed by the current proxy parser. This requires a match
identity adapter and populated source data before an app contract change helps.

## Minimum implementation sequence

1. **More football.** Add verified competition mappings for the first eight
   table rows. The app already accepts these soccer paths when advertised.
   Add league-scoped aliases for Cologne, PSG and, separately, MLS. Preserve
   abstention and add wrong-club/women's/youth collision regressions. No new UI
   or follow migration is needed.
2. **NFL/NBA/NHL artwork independently of broadcasts.** Fix date discovery first.
   Give artwork its own enabled competition list, preserving the current
   `SPORTS_COMPETITIONS` default behaviour, schedule cache reuse and worker
   coalescing. The same v1 two-team publication can represent these fixtures;
   enabling artwork must not silently enable unreviewed broadcast matching.
   In the app, separate artwork eligibility/source discovery from the
   football-only `proxyCompetition` and broadcast identity validator. Keep the
   exact competition/event/team/start checks for both consumers. Test an
   artwork-only proxy with no broadcast capability.
3. **Prove more active-season team coverage.** MLB/AFL/URC are useful candidates.
   Resolve league-scoped team identity differences for rugby/NRL and validate
   source consistency for WNBA. Do not expand negative matches into guesses.
4. **F1 session contract and adapter.** Use the measured five-session weekend as
   a starting fixture, with additional sprint/reschedule cases before shipping.
   Keep UFC, tennis and cricket on current fallbacks until their data and
   identity requirements are met.

Keep one registry for verified competition mappings rather than divergent ESPN
and Sportarr allowlists. The current worker has a 90-second pass deadline and a
shared Sportarr pacer of at least 1.5 seconds/request. All measured windows fit
one page, but a broad cold sweep, extra date padding and large college/tour feeds
need their own budget check. Keep partial-window rejection and the five-page
ceiling. No catalogue-wide app requests or new main-thread work are needed.
