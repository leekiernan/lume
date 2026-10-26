# Trakt recommendation sections

Library layout settings offer **Trakt Recommendations** beneath the custom-list
URL editor while Trakt is connected. Its pencil edits the title; its plus adds
one ordinary custom section to the current area. Each profile and area keeps its
own title and layout. Once added, the usual reorder, visibility, hero and
tvOS Top Shelf controls apply in the Sections list.

The section stores its canonical API URL in the existing custom-section format:

| Area | Source |
| --- | --- |
| Home | `/media/recommendations` |
| Movies | `/movies/recommendations` |
| Series | `/shows/recommendations` |

These are the endpoints used by the [Trakt web client](https://github.com/trakt/trakt-web/blob/main/projects/client/src/lib/requests/queries/media/mediaRecommendedQuery.ts).
They differ from the older `/recommendations/movies` and
`/recommendations/shows` endpoints in the published API contract. They are not
yet described in that contract, so connected-account device testing should
confirm access for Lume's client ID. An endpoint failure is surfaced through
the existing row failure state; it never silently substitutes legacy results.

Lume preserves response order and applies its usual local catalogue and hidden
category filters. It does not merge separate rankings or sort on scores. The
web client also keeps a browser-local daily order, so an already-open web page
can differ from a new server response. Website-specific discovery filters are
not imported; the requests use the web defaults `ignore_watched=true` and
`ignore_collected=true`.

One bounded request retains up to 100 candidates; the rail resolves at most 20
local titles and the hero at most eight. Existing list membership caching keeps
only media kinds and TMDB IDs, uses the connected account in its cache key,
and renders cached membership before revalidation. Signed-out sources do not
restore anonymous membership. Remembered hero artwork is account-scoped too.
Top Shelf membership and export eligibility also carry an opaque account scope,
so disconnecting or changing Trakt clears personal recommendations even when
their source area has not been reopened. If another profile is active, a retained
snapshot containing the old account's recommendations is cleared until the
followed profile can rebuild it.

Regression coverage includes request shape and ranking, area-specific sources,
missing IDs, empty/error responses, account/cache isolation, title persistence,
and signed-out loading. Physical-device verification should check adding,
renaming, reordering, hero promotion, removing and re-adding the section, then
disconnecting Trakt while the recommendations are visible.
