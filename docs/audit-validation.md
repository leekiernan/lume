# Follow-up validation sweep

Baseline: `3acfa9f2` on main. This pass follows the concrete paths introduced in
`audit-boundaries.md` through their callers, persistence, exports and failure
handling. It also checks adjacent WebDAV, sports and Top Shelf paths. It is not
a claim that every possible code path or third-party engine has been proved.

## Findings addressed

- **Artwork transport isolation.** Account-isolated image keys do not isolate
  Foundation's URL-only HTTP cache. Top Shelf used the default cache after
  authentication moved into headers. Both artwork transports now share an
  ephemeral configuration without ambient HTTP caching, cookies or stored
  credentials. Top Shelf also rejects non-success HTTP responses before decode.
- **Header diagnostics.** URL and Basic-auth redaction alone did not cover the
  explicit Bearer, Plex, Emby and MediaBrowser token headers. The common log
  scrubber covers these formats, including short Basic credentials in an
  Authorization header; regression cases check repeated redaction as well.
- **Download artifact boundaries.** Container extensions came directly from
  provider metadata. Only short alphanumeric extensions now enter filenames;
  restored task descriptions must name a basename. Recovery/deletion recognize
  a legacy stem or exactly one UUID attempt suffix, not any dotted sibling.
  Download URLs require a known supported source and an HTTP(S) origin.
- **Download recovery work.** Recovery previously scanned the entire directory
  for each stranded row. One directory index now resolves each row's candidate
  files before validation. This removes the files-times-rows search; it is a
  structural complexity improvement, not a wall-clock benchmark claim.
- **Background failure delivery.** Success held the system completion budget,
  but validation/network failures could release it before status was durable.
  Failure work now enters the delivery group before the delegate returns, and
  finish-events waits for persistence. A test drives the actual delegate path
  with an owned, non-networking session and reads status after completion.
- **Tracker import ownership.** Durable account/profile IDs are appropriate for
  parked history, but not sufficient for an in-flight A→B→A operation. Imports
  capture viewer and session generations, recheck after token/fetch waits and
  after the background executor hop, and hold the projection gate only during
  synchronous local application. A reconnect to the same account retires the
  previous generation. No generation is persisted in parked history.
  Transient Trakt scrobbles also capture the account generation before joining
  their serial queue, so an old event cannot acquire a replacement account's
  credentials. This account-only permit deliberately preserves the connection's
  existing global (not profile-owned) behavior.
- **Progress transaction failure.** A failed save left mutations on the writer's
  context, so a later title's save could flush them. Failures now roll back;
  held live-channel touches remain queued until a successful retry. Tests inject
  the failure deterministically rather than relying on filesystem permissions.
- **WebDAV response contracts.** The first multistatus response need not describe
  the collection. Self-responses are excluded by identity, not position. Slash
  normalization edits the path before the query/fragment. Directory redirects
  cannot cross origins, and both files and folders must remain inside the share
  after decoded dot-segment normalization. Persisted content IDs are unchanged.
- **Sports cache claims.** A roster-only update no longer claims a fresh fixture
  schedule. Partial schedule responses retain failed windows without dating the
  whole schedule as newly fetched. Failed fields merge from the current cache,
  not an older pre-request copy. Future-dated cache entries cannot suppress
  refresh indefinitely, and fixtures abandoned as live are not retained forever.
- **Top Shelf export reads.** A failed category read now prevents content export
  instead of silently removing visibility restrictions. Visibility is read once;
  recorded rows resolve titles in bounded, kind-qualified batches rather than
  one lookup per title. Recorded order, hidden-channel checks and playlist
  restrictions remain in force.
- **Test ownership.** Progress/resume tests now participate in the existing
  shared/exclusive global-state protocol. A profile-switch test must not retire
  a different test's writer; storage-wide clears require exclusive access.

## Follow-up dead-code cleanup

A reference sweep of 913 shipping Swift files, cross-checked against unit tests,
performance tests and scripts, identified seven declarations without callers:

- `M3UClient.downloadEPG`, superseded by the conditional `downloadGuide` path.
- `SportsLeague.withLogo` and `TopShelfSettings.followsActiveProfile`.
- `View.posterTitleFrame`, the `MovieGenreView` and `SeriesGenreView` aliases,
  and the unused `TrackerHistoryMutation` alias.

These are removed in separate, focused commits. The genre-grid documentation
now lives on `CatalogGenreView`, which the app actually opens. Framework-invoked
callbacks and test hooks were not treated as dead code merely because shipping
call sites do not name them. No persisted fields or decoder contracts changed.

The startup-timeout closure also now carries its `@MainActor @Sendable` function
type explicitly. This removes our callback-conversion compiler warning without
changing when the watchdog fires or adding a KSPlayer workaround.

## Stateful ownership follow-up

The next pass encapsulates six lifetimes without changing catalogue identity,
profile ownership of viewing state, provider fallback or third-party engines:

- **OpenSubtitles account.** `OpenSubtitlesSessionMachine` represents login,
  connected/signed-out state and account generations. Local logout happens
  before best-effort remote logout. Late login successes/errors, searches,
  downloads and language-cache updates cannot publish into a retired session;
  a successful account replacement also retires work begun during login.
  Injectable client, keychain/cache boundaries enable suspended-request tests
  without changing the household's credentials or subtitle files.
- **Playback hosts.** Idempotent activity leases aggregate indexing pauses and
  Multi-View QoE suspension across overlapping hosts. Now Playing selects one
  host and fences asynchronous artwork/EPG/sampler work by stream generation.
  Engine transports are host-qualified too: mounting a new host never borrows
  an old host's transport. PiP teardown checks both host and engine identity,
  including a replaced engine in the same host; stale callbacks cannot dismiss
  the replacement.
  Redirect tokens are host-local, and clearing a cache revokes in-flight probes.
  These are distinct ownership policies, not a new all-purpose playback machine.
- **Sports polling.** A shared visibility modifier owns an explicit subscription
  per surface. Duplicate appearances/releases cannot alter another surface's
  subscription. Disabling the feature stops work, retaining visible interests
  so re-enabling can restart the loop; profile changes still cancel old work.
- **Guide refresh.** `EPGRefreshMachine` extends the existing admission gate with
  running-job identity and typed debt: enrichment, conditional guide or forced
  guide. Provider work dominates enrichment, and forced recovery is not weakened
  by a later trigger. Cancelling for a VOD content sync retains metadata-only
  intent rather than promoting it to a provider download. Manual refresh still
  bypasses content-sync admission. Publication fences and successful schedule
  timestamps remain in the executor.
- **VLC resume seek.** Waiting, issued and landed replace three parallel flags.
  The machine retains VLC's seekability and two-second landing tolerance, and
  rejects nonfinite/unrepresentable resume positions before `VLCTime` conversion.
  AVPlayer's different readiness contract is deliberately not folded into it.
- **Profile preferences.** `ProfilePreferencesSynchronizer` owns a single
  snapshot/JSON baseline, import merges, apply suppression and debounced writes.
  `ProfileManager` retains roster/selection/projection responsibilities. Existing
  unknown-field preservation and pre-import cloud-seeding rules remain intact.
  A failed preference save restores only its own model fields, leaving edits
  dirty for a real retry without rolling back unrelated context mutations.

The tests exercise stale completions using controlled suspension, overlapping
leases, typed refresh debt and isolated preference stores. Physical playback,
PiP and system-card presentation still require device validation; pure ownership
tests do not claim to prove platform UI behavior.

Suggested device checks are ordinary playback/resume, source/engine switches,
PiP closure and system transport controls, overlapping player/Multi-View windows,
and disabling/re-enabling Sports or switching profile while a sports surface is
visible. No recovery build or storage migration is required for this pass.

## Accepted player diagnostics

The reported startup messages do not currently accompany a playback failure.
Per the requested complexity trade-off, this pass adds no KSPlayer fork,
mounting adapter, method interception or log suppression to work around them:

- KSPlayer's constructor still calls synchronous audio-session APIs on the main
  thread after Lume's off-main activation. `PlaybackAudioSession` serializes the
  app's ownership; it does not control those library calls. Its comment now
  states that boundary rather than implying pre-configuration prevents them.
- KSPlayer's coordinator publishes `isMaskShow` during synchronous preparation.
  This is the source-derived likely path for the view-update publication warning;
  deferring Lume's callbacks does not defer the coordinator's own publications.
  Revisit if playback or UI symptoms appear, rather than asserting this warning
  is harmless in every situation.
- `preparing` and `prepareToPlay` are ordinary lifecycle diagnostics. FFmpeg's
  HLS probe warns for legacy `application/x-mpegurl` or `audio/x-mpegurl` MIME
  types and then accepts the input; that warning is not a rejected stream.

## Branch review

A later external sweep listed thirteen findings against this branch. Each was
traced to current code, and none holds: every one describes code that commits
already on `main` had replaced. The cited lines no longer exist. For example,
`RelatedTitlesResolver.swift` is 71 lines, and `StreamRedirect` already reads
headers only.

| Finding | Status | Where it was fixed |
|---|---|---|
| Resume points shared between profiles | Already fixed | Keyed by profile and title (`RecentResumePoints.Key`); cleared by `StorageManager.clearWatchHistory` |
| Late token refresh undoes a disconnect | Already fixed | Refresh re-checks generation and refresh token on the main actor before `apply` |
| Related rails ignore restrictions | Already fixed | `RelatedTitlesResolver` requires `ContentRestriction` and filters before choosing a copy |
| Movie/series TMDB fallback | Already fixed | Separate namespaces; the test asserts no cross-kind match |
| Media-server TMDB bypasses policy | Already fixed | All four adapters call `applyCatalogueTMDB` |
| Download queue and persistence order | Already fixed | `DownloadLifecycle`, `promoteIfNeeded`, serial status writes |
| `displayURL` shows credentials | Already fixed | `DisplayAddress.origin` keeps scheme, host and port only |
| Redirect probe downloads the body | Already fixed | `bytes(for:)`, cancelled at headers |
| Maintenance holds the whole catalogue | Already fixed | `CatalogMaintenance.mutate` pages by key with a fresh context |
| Indexer owner queries per title | Already fixed | Per-chunk source map, batched writeback lookup |
| Quadratic episode bulk actions | Already fixed | Changes applied together; recency recomputed once |
| Sports cache I/O on main | Already fixed | `SportsCacheIO` actor with coalesced writes |
| Sports empty and failed look the same | Already fixed | `SportsFixtureWindowResult` per requested window |

The same review traced every commit on this branch for regressions and found
none in playback fallback, Picture in Picture, remote commands, reconnect,
profile switching, imports or downloads. It did find the following, now fixed:

- **A WebDAV sync could empty the catalogue.** A listing whose hrefs name
  another authority, such as a TLS proxy answering `https://nas:5006` with
  `http://nas:5005/…`, had every entry rejected by the share boundary. The walk
  then completed with nothing and pruned every row. A listing with entries but
  none inside the share now aborts as a bad response.
- **A history clear from another device didn't reach this device's resume
  cache.** It lands as progress 0 with no date, and a record from this run beats
  a model with no date. Cloud applies and orphan resets now drop that title's
  record (`RecentResumePoints.forget`).
- **A refresh that landed after a disconnect left a valid token pair** on the
  server until it expired. That pair is now revoked.
- **A failed OpenSubtitles sign-in cancelled the current account's download.**
  The attempt now carries its own token, and only a successful sign-in revokes
  the account's permits.
- **A failed preference save waited for the next edit.** A relaunch before then
  let the cloud copy win. Failures now retry on their own: three tries, backing
  off from 2 s to 60 s.
- **Related and collection rails kept a title after its category was hidden**
  while the detail page stayed open. They now re-resolve when visibility changes.
- **Schemeless credentials survived log redaction:** `?api_key=` and similar
  query items, `X-MediaBrowser-Token`, and Xtream `/live|movie|series|timeshift/
  user/pass/` paths.
- **An m3u title with a non-HTTP stream offered a Download button that did
  nothing.** The button is now gated per title on the same URL check.
- **Player activity leases** are taken in `onAppear`, the pair of `onDisappear`,
  instead of in a task.
- **Two flaky test groups.** The `StreamRedirectTests` timing cases ran on the
  main actor, so a full parallel run counted 8–11 s of waiting for the main
  thread. They now run off it. `ProfileProjectionGateTests` gave its success
  waits more time on a busy global queue.

Deliberately left as they are:

- **The EPG `finish` guard.** When it fails, a newer job owns `task`, so
  clearing `task` there would orphan the live job.
- **EPG observation churn.** It happens only on rare owe and queue events.
- **WebDAV's strict redirect origin.** See the redirect section.

The five scheduled follow-ups have implementations on this branch; see
**Audit follow-up implementation** below. The original typed-connection finding
was partly stale: playback already used `PlaylistConnection`; the remaining
provider API/sync operations did not. Simkl's scrobble API is currently a no-op,
so the queued-scrobble finding concerns Trakt, not a second Simkl playback queue.

Remaining non-blocking follow-ups:
- **Smaller items:**
  - The episode-menu boundary checks are O(n²) per season list.
  - Top Shelf has no image cache.
  - A case-insensitive server (IIS) may echo its own folder as a child.
  - Now Playing has no handback between macOS player windows.

## Deliberate boundaries and next measurements

The enhanced proxy remains optional. This pass does not alter provider catalogue
IDs, CloudKit schemas, viewing-identity policy or playback focus/navigation.
It does not inspect, move or change API secrets, and does not add `_NOTES` to Git.

Two adjacent areas merit dedicated validation rather than an unmeasured rewrite:

1. **Native playback redirects — measured and fixed.** Each engine runs its
   own HTTP and follows redirects itself, so `PlaybackRedirectContractTests`
   opens a loopback origin exactly as each coordinator does and records what
   a cross-origin redirect target receives. Handed the stream's headers as
   they were, FFmpeg (KSPlayer) sent all of them on — WebDAV Basic, the
   Jellyfin `Authorization` token and `X-Plex-Token` — and AVFoundation
   dropped `Authorization` but sent `X-Plex-Token`. FFmpeg also applies its
   `headers` option to every other URL it opens.

   Query-only handoff prevented that leak but broke authenticated relative
   redirects: a new path dropped the token. The follow-up adds shared
   `PlaybackResourceResolver` preparation for protected HTTP streams. It follows
   at most eight source-origin hops, with a four-second total deadline, using
   Range GETs whose bodies are cancelled at the headers. Same-origin hops retain
   authentication; the first foreign target is handed off without source headers
   and is not probed. The same host upgrading to HTTPS (`http://` behind a TLS
   proxy, Jellyfin's 8096 → 8920) keeps authentication; TLS proves the host
   name whatever the port. Non-HTTP targets, redirect userinfo, HTTPS
   downgrades and loops fail closed. A timeout or transport error does not: the
   original resource is handed off unresolved — the query/userinfo handoff,
   which a foreign redirect still replaces — so a slow NAS is never refused
   outright. Unprotected streams keep their existing path.

   `PlaybackCredentials` builds transient native inputs from the prepared
   resource: tokens as query items, WebDAV Basic as userinfo (FFmpeg told
   `auth_type=basic`). AVFoundation alone keeps `Authorization`; no engine gets
   `X-Plex-Token` as a header. Jellyfin uses canonical `ApiKey`, with `api_key`
   retained for Emby's documented contract. These URLs never replace the stored
   media identity. Engine-owned preparation is cancelled and retired on
   replacement/teardown; authenticated retries start from the original source.

   API calls have a stricter, separate policy: Plex, Jellyfin and WebDAV reject
   foreign-origin redirects entirely, including credential-bearing login POSTs.
   Playback may legitimately use a CDN; account APIs may not forward credentials
   or request bodies to one. Plex and Jellyfin follow their own host's HTTPS
   upgrade; WebDAV does not, because its listings are checked against the
   configured root's origin and an upgraded listing would read as empty.

   **Open, for device testing:** on KSPlayer, an authenticated stream switch
   (next episode, the tvOS episode rail) unmounts the player while the new
   source is prepared and mounts a fresh one, where it used to swap the URL in
   place. That likely ends Picture in Picture on auto-advance for Jellyfin, Plex
   and WebDAV; unauthenticated streams still swap in place.

   Artwork retains canonical `ApiKey` in transport so it works without legacy
   authorization. With an explicit account scope, that token is excluded from
   image cache identity; image tags and sizing remain significant. Unscoped
   callers still fingerprint every token through the transport URL and headers,
   including duplicate aliases, rather than risk sharing private artwork.

   This covers the initial direct-file redirect chain, not every dynamic request
   a native demuxer might make. Jellyfin/Plex currently use single-file direct
   play. Arbitrary authenticated HLS and redirects that change on later seeks
   need their own contracts. libvlc's measured redirect-plus-401 bad free is a
   library defect. Pre-resolution removes the initial native redirect, but VLC's
   foreign-target probes deliberately do not challenge for Basic authentication.
   Challenging foreign targets remain unverified, not a claimed VLCKit crash fix.
2. **Response-size enforcement before allocation — measured and adopted.**
   `BoundedResponse` reads a body on the caller's own session through a
   per-task data delegate: a declared `Content-Length` over the limit is
   refused before any body is read, and an undeclared body is cancelled at
   the chunk that passes it. The bound is on the application's retained body,
   not Foundation's queues, decompression, cache, allocator capacity or concurrent
   reads. The decoded body is checked too. HEAD/304 representation lengths are
   not body budgets, and those responses are allowed to complete rather than
   cancelled, so their connection stays reusable. Proxy clients discard non-success bodies at the headers,
   preserving 404 unsupported and 5xx host-outage semantics without collecting
   their error pages. Caller cancellation still cancels the request.

   The earlier peak-memory table is withdrawn: external-server mode still
   allocated 8 MiB + 64 MiB of unused local fixtures before checking its URL.
   Those figures were not reader-only measurements. The corrected harness
   constructs local bodies only in local mode. `Scripts/network-read-fixture.py`
   supplies a reproducible out-of-process server; compare one Benchmark test per
   process, never subtract 72 MiB from the old peaks to invent new measurements.

   Corrected runs at `e37895ff`, on the same iOS 27 iPhone 17 Pro simulator,
   used that external server, Benchmark optimization and five measured iterations
   per case. Peaks below are the whole test-host process in decimal MB, excluding
   fixture storage, not the reader's incremental allocation:

   | Payload / budget | Reader | Mean process peak | Peak RSD |
   |---|---|---:|---:|
   | 64 MiB undeclared / 8 MiB | Collect then check | 175.31 MB | 0.97% |
   | | Bounded | 45.74 MB | 0.47% |
   | Five accepted 8 MiB reads | Collect then check | 58.44 MB | 0.45% |
   | | Bounded | 51.93 MB | 0.44% |

   CPU and clock RSDs were mostly above 10% (up to 57%); no speed or accepted-path
   CPU-overhead claim is made from them. All four cases passed their byte-count
   assertions, and a separate test confirmed keep-alive connection reuse.
   Evidence: `/tmp/lume-redirect-fixes-perf-{oversized,accepted}-{collect,bounded}.xcresult`
   and `/tmp/lume-redirect-fixes-perf-connection-reuse.xcresult`.

   The metadata and sports batch readers (8 MB) and capability negotiation
   (64 KB) now enforce their limits this way, with the same outcomes as
   before for an oversized body. Artwork has no accepted-size limit to
   enforce; choosing one is a separate decision.

## Verification

Validated on 17 October 2026, with the final source changes at `0f59f39e`:

- **LumeTests:** 3,540 tests across 506 suites passed; zero failures or skips.
  Swift Testing reported 340.243 seconds. This ran on an iPhone 17 Pro simulator
  with iOS 27.0, not on macOS or tvOS.
- **Builds:** iOS build-for-testing, tvOS build and macOS build passed, each using
  private DerivedData and the shared package clone.
- **Formatting and lint:** all Swift commits passed the SwiftFormat/strict
  SwiftLint pre-commit checks. The final diff passes `git diff --check`.
- **Scope check:** no `_NOTES`, project-file, localization or API-secret changes.
  No CloudKit schema migration or provider catalogue identity change.

The final run's evidence is `/tmp/lume-validation-final.xcresult` and
`/tmp/lume-validation-final.log`. UI automation and physical-device checks were
not run. No Debug timings are presented as performance benchmarks. Physical-
device checks remain the board's responsibility, not a prerequisite for
engineering review. The branch remains unmerged pending review.

### Follow-up cleanup verification

Validated after the cleanup and callback annotation at `a134fef8`:

- **87 targeted regression tests passed**, with zero failures or skips, on the
  same iOS simulator. Coverage includes guide downloads, Top Shelf settings,
  poster adapters, genre derivation, tracker outboxes, sports caches/retention,
  audio-session leases, startup state/deadlines, redirect probes and metadata
  delivery. Parameterized cases account for 104 individual executions.
- **iOS build-for-testing, tvOS build and macOS build passed.** The startup
  callback conversion warnings are absent from all three final builds.
- All cleanup commits passed formatting/lint hooks; the final diff passes
  `git diff --check`. The seven removed names have no remaining Swift references
  in shipping code, tests, performance tests or scripts.

The earlier full-suite result above remains the baseline; it was not re-run for
this deletion-only cleanup and callback annotation. Follow-up evidence is in
`/tmp/lume-audit-cleanup-tests.xcresult` and the three
`/tmp/lume-audit-cleanup-<platform>-final-build.xcresult` bundles. Only regenerable
task build caches are removed; these results and the shared package clone stay.

### Stateful ownership verification

Validated on 17 October 2026, with the final source changes at `299e8ee9`:

- **The full LumeTests suite passed:** 3,573 tests, zero failures or skips.
  Parameterized cases account for 3,992 individual executions. This is 33 more
  test methods than the earlier full-suite baseline, not a targeted-only run.
  The iPhone 17 Pro simulator ran iOS 27.0; Xcode reported 359.5 seconds for the
  test action including runner startup, not a performance benchmark.
- **iOS build-for-testing, native tvOS build and macOS build passed.** The final
  native builds reported zero warnings. The iOS test build retains existing
  test-source warnings; none originate in the new ownership/machine files.
- All Swift commits passed SwiftFormat and strict SwiftLint hooks. The final
  diff passes `git diff --check`. No `_NOTES`, project-file, localization,
  credentials, provider contract or persisted schema changes were included.

Evidence is `/tmp/lume-state-ownership-tests.xcresult` and
`/tmp/lume-state-ownership-<platform>-verified-build.xcresult`. Task-owned
DerivedData is removed after verification; the result bundles and shared package
clone are retained. Physical-device/UI automation checks were not run. The
branch remains unmerged for review.

### Redirect and bounded-read verification

Validated on 17 October 2026 at `aa14de1a`, on an iPhone 17 Pro simulator
running iOS 27.0:

- **LumeTests:** 3,573 tests; 3,570 passed. The 3 failures were timing budgets
  (`StreamRedirectTests` ×2, `ProfileProjectionGateTests`) exceeded while the
  tvOS and macOS builds ran alongside; both suites then passed alone twice,
  13 of 13 each run.
- **Builds:** tvOS and macOS builds passed with private DerivedData and the
  shared package clone.
- **Benchmarks:** the original external-mode runs included unused in-process
  fixtures. Their peak-memory attribution is withdrawn; see the correction above.
- **Formatting and lint:** SwiftFormat and strict SwiftLint passed on every
  changed file.

Four suites (`EPGRefreshMachineTests`, `NowPlayingSessionOwnershipTests`,
`VLCResumeSeekMachineTests`, `ActivityLeaseTests`) did not compile at the
redirect branch's base; `af412bd0` fixed them there. This branch fixed the same
suites itself (`f57e9505`, `ab1665a1`), and the merge keeps those versions.
Physical-device playback of WebDAV, Jellyfin and Plex through each engine
remains the board's check.

### Review-fix verification

The follow-up fixes are isolated in conventional commits on
`fix/redirects-and-bounded-reads`; final shipping/test source is `b1807507`.

- **Final LumeTests:** 3,596 tests passed (4,068 executions including parameterized
  cases), zero failures or skips, on the iPhone 17 Pro simulator running iOS 27.0.
  No builds ran alongside this suite. Evidence is
  `/tmp/lume-redirect-fixes-final-tests.xcresult`.
- iOS build-for-testing, tvOS build and macOS build passed on the final source,
  using private DerivedData and the shared package clone.
- The native loopback tests cover FFmpeg, KSPlayer's AVFoundation path, Lume's
  AVPlayer and VLC. Same-origin authentication assertions exclude preparation
  requests, so the native request itself must authenticate. Foreign-host and
  foreign-port probes check that source credentials do not arrive there.
  Modern Jellyfin probes accept canonical `ApiKey`, not legacy `api_key` alone.
- Authenticated API redirects, including login POSTs, are tested separately.
  Reader regressions cover oversized error pages, host cooldown, bodyless
  responses, decoded gzip limits, session-delegate forwarding, cancellation
  and repeated cancellation before starting. Preparation tests cover replacement
  ownership, unsafe targets, loops, a total deadline and a cancelled caller.
- Scoped artwork tests retain canonical authentication in transport while
  checking token rotation, account isolation, duplicate aliases and image tags.
- The four corrected memory benchmarks and the connection-reuse check passed;
  measurements and their limitations are recorded above.
- Every Swift commit passed SwiftFormat and strict SwiftLint. The final diff
  passes `git diff --check`. No `_NOTES`, project-file, localization, schema,
  catalogue-identity or secret changes are included.

Final build evidence is in
`/tmp/lume-redirect-fixes-final-{ios,tvos,macos}-build.xcresult`.
UI automation and physical-device playback were not run. Physical WebDAV,
Jellyfin and Plex checks remain the board's responsibility; arbitrary authenticated
HLS is outside the verified direct-file contract.

### Branch review verification

Validated on 17 October 2026 at `fe55f5a5`, after merging
`fix/redirects-and-bounded-reads`, on the iPhone 17 Pro simulator running iOS 27.0:

- **LumeTests:** 3,615 tests; 3,613 passed. The two failures were load-sensitive
  tests unrelated to these changes: in one, a `DispatchQueue.global()` block
  didn't start within 10 s (`ProfileProjectionGateTests`); the other was a
  coalescing count (`LumeMetadataDeliveryTests`). Both suites then passed alone
  three times, 36 of 36 each run.
- **Rotating timing failures.** Across five full parallel runs, a different
  timing test failed each time. The two that recurred (`StreamRedirectTests`
  and the gate test) are fixed. The root cause is still open: something in a
  full run starves the GCD and cooperative pools for seconds. Finding it,
  likely tests that block pool threads, is a follow-up.
- **Builds:** tvOS and macOS passed, with private DerivedData and the shared
  package clone.
- **Formatting and lint:** SwiftFormat and strict SwiftLint passed on every
  changed file, through the pre-commit hook.

### Audit follow-up implementation

Implemented on `fix/audit-validation`, 18 October 2026, in separate conventional
commits. No catalogue IDs, SwiftData schema, viewing-profile ownership, proxy
fallback rules, `_NOTES` or secrets are changed.

- **Source-owned artwork.** `ProviderArtworkAccount` snapshots the typed source
  connection. A small observed playlist table supplies current credentials;
  images never query SwiftData individually or guess an account from a hostname.
  Cards, detail heroes, episode stills, Continue Watching, hero prefetch, Downloads,
  favourites, player information and Now Playing carry the catalogue owner.
  Cached warm-start heroes carry their existing playlist owner before a matched
  item exists, through the shared `HeroFeedPage` surface on every platform.
  Plex/Jellyfin/Emby sync stores token-free routes. The image request attaches
  auth only to the source origin; Jellyfin retains modern canonical `ApiKey`
  transport support. Successful caches use an account-qualified identity;
  in-flight and failure keys additionally distinguish credentials, so a rotated
  token can retry without dropping successful artwork. Public CDN images retain
  their existing cache identities and work without media-server credentials.
- **Artwork cleanup and exports.** A resumable, once-per-device pass strips the
  old URL credentials in 250-row pages, changing only the three provider-artwork
  columns. It does not rebuild stores or touch history/favourites. Top Shelf
  materialises private artwork in the app and exports files, not authenticated
  URLs. For manually pasted Plex tokens without a known account ID, isolation
  remains conservative: changing that token changes its private cache scope.
  Username-backed Plex and user-ID-backed Jellyfin/Emby scopes survive rotation.
- **Queued scrobbles.** Credential/import lifetime and transient delivery lifetime
  are separate. Same-account cloud rotations retain delivery permits; explicit
  disconnect/reconnect and account replacement retire them. The new credential's
  account is confirmed before delivery. Rotation during a local refresh or
  identity lookup retries against the replacement pair, with bounded churn.
  Imports retain their stricter generation fence. Trakt remains globally
  connected; this is not a change to profile/account ownership.
- **Paged tracker imports.** Shared `TrackerImportPages` holds the profile gate
  for one transaction, then releases it and yields. Every page has a fresh context
  and rechecks profile/account lifetime before writing. Movies use groups of 100
  remote title IDs; shows and pauses use 10. Duplicate records for one title stay
  together, preserving last-record/newest-pause semantics. Completed history still
  precedes pauses. Earlier committed pages remain valid if a later page is
  refused; the result reports failure rather than claiming a complete import.
  This bounds the history-sized critical section, not wall-clock lock latency:
  one unusually large series can still take a substantial transaction, and
  parked-state serialization remains per changed page. Unchanged parked history
  does not rewrite its file; deterministic file-mtime tests cover both trackers.
- **Typed provider operations.** Xtream API/guide/capability URL assembly,
  Plex and Jellyfin/Emby login/sync, WebDAV walking, m3u acquisition and Stalker
  configuration consume `PlaylistConnection`. Unknown or mismatched source types
  cannot borrow unrelated credential columns. Existing provider paths, duplicate
  query items and credential encoding are retained. Empty endpoints now fail
  validation instead of producing unusable relative URLs containing credentials.
  Raw fields remain where they
  belong: the validated snapshot initializer, settings editing, storage export
  and credential persistence.
- **Startup accounting.** `PlaybackStartupSupervisor` accepts first-frame proof,
  owns the terminal latch/deadline, and centralises QoE session/first-frame/failure/
  teardown reporting. QoE calls are owner-qualified, so a retired engine cannot
  claim the replacement's first frame. Mount-time proof is retained; a new load
  cannot borrow a previous stream's proof. Engines keep their decoder-specific
  proof inputs, reconnect behavior, and published UI projections. No KSPlayer
  dependency patch or player policy change is needed.

### Audit follow-up verification

Validated on 18 October 2026 at source/test commit `5c92d236`:

- **LumeTests:** all 3,636 tests passed (4,119 parameterized executions), zero
  failures or skips, on an isolated iPhone 17 Pro simulator running iOS 27.0.
  The final full run took 448 s with test parallelization disabled. No rotating
  timing failure reproduced in either full sweep; this does not resolve the
  separate suite-starvation investigation described above.
- **Builds:** iOS build-for-testing, native tvOS and native arm64 macOS all
  succeeded, using private DerivedData and the shared package clone. The iOS
  build retains two existing actor-isolation warnings at
  `WidgetSnapshotTests.swift:83`; tvOS and macOS reported no warnings.
- **Regression coverage:** source/account isolation, credential rotation and
  foreign origins; token-free sync and 251-row cleanup/idempotence; cached-hero
  ownership; tracker rotation during refresh and account replacement; paged
  import cancellation/context boundaries and unchanged parked-file timestamps;
  validated endpoint assembly; startup proof and QoE ownership.
- **Formatting and lint:** every Swift commit passed SwiftFormat and strict
  SwiftLint through the pre-commit hook; `git diff --check` passed.

The first full sweep exposed two assertions pinning the intentionally replaced
contracts (persisted artwork tokens and credential-bearing relative URLs for an
empty endpoint). Those tests now assert the new storage/authentication boundary
and early endpoint rejection; the final sweep above includes both corrections.

Evidence: `/tmp/lume-audit-followups-final-tests.xcresult` and
`/tmp/lume-audit-followups-final2-build-{ios,tvos,macos}.xcresult`.
No UI automation or physical-device testing was run. Board smoke checks should
cover Plex/Jellyfin artwork before and after token rotation (including cold-start
heroes and Top Shelf), progress saves during history import, and open/swap/retry
playback. The branch is ready for review, not yet merged.

### Follow-up review

Each area was reviewed against its intent before `fix/test-stalls` was merged.

- **Trackers:** adequate. Same-account rotation keeps queued scrobbles. A
  different account, a disconnect or a reconnect still drops them. The retry
  during refresh is bounded at three. Import pages each re-check the profile
  and account. Added the missing test: a profile switch between pages stops
  the remaining writes.
- **Typed connections and startup accounting:** adequate. URL assembly is
  byte-for-byte the same, and nothing that synced before now fails validation.
  Reconnect, retry and fallback keep their meaning. A guide source of a playlist
  type this build doesn't know (synced from a newer build) is now left alone
  instead of deleted.
- **Artwork:** adequate after three fixes.
  - The legacy-token cleanup was awaited ahead of download restore and profile
    bootstrap, paged by offset and held every row in one context. It now runs
    detached through `CatalogMaintenance`'s keyset pages, tested on a real
    store file.
  - An m3u or Xtream playlist on a Plex/Jellyfin origin (a Jellyfin Live TV
    m3u, say) resolved its own logos to nothing. They load as before, without
    the account's credentials.
  - A cross-origin redirect whose `Location` echoed the original address
    carried Jellyfin's query `ApiKey` to the new host. Media-server credential
    query items and userinfo are now removed on that hop. The original fix
    only covered top-level parameters. Nested return addresses (`rd=`, or any
    other parameter name) are now inspected without rewriting their transport
    bytes: a cross-origin redirect embedding authentication parameters or
    userinfo is refused. Inspection covers relative URLs, nested wrappers and
    repeated percent encoding, with bounded depth and work; exceeding either
    limit also refuses the hop. ASCII-only inspection retains opaque non-UTF8
    CDN signature bytes and cannot silently lose a value while decoding it.
    Harmless signed CDN URLs and same-origin redirects remain byte-identical.
  - Added a Top Shelf test that renders a token-free route with its owner's
    credential.

Open, non-blocking:
- **Offline artwork after the upgrade.** Old private caches were keyed by
  token, so downloaded titles show blank posters offline until the device is
  online once.
- **Leftover token bytes.** Old token bytes remain in SQLite free pages and
  in hero warm-start defaults until overwritten.
- **Add-time URL checks.** They accept schemes that sync later rejects
  (`davs://`).
- **Engine-level QoE.** There is no test of the counts per engine.

### Suite stalls

Sampling a full parallel run found three causes. The rotating timing failures
were symptoms of them.

- **Observers that block posters.** `addObserver(queue: .main)` holds a
  background poster until the main thread runs the block, so every background
  `ModelContext` save, `UserDefaults` write and store remote change waited on
  main. One sample caught 54 threads at once in
  `-[NSOperation waitUntilFinished]`.
- **A deadlock risk during profile switches.** `ActiveProfileStore` wrote
  defaults while holding its lock. During a switch, a background poster could
  hold that lock while waiting on main, and main could be waiting for the lock.
  `addMainActorObserver` and a write outside the lock fix both, in the app as
  well as in tests.
- **The live app under the unit tests.** The unit-test host launched the
  full app, which reacted on the main thread to the tests' saves and writes.
  The host now shows a blank window.

Test waits counted in yields or a few seconds now poll to a 30 s backstop
(`eventually`). The in-flight profile-switch tests hold the projection gate
instead of racing the switch.

`xcodebuild`'s default `-collect-test-diagnostics on-failure` runs a
sysdiagnose with a 600 s timeout after any failing test. That turned 2-minute
runs into 12–17 minutes. Command-line runs now pass `never` (`AGENTS.md`).

Full parallel runs on the merged stall fixes passed 3,620 of 3,620, in 89 s
and 107 s, against about 240 s and two or three failures per run before.

Final verification at `773c0fee`, with the follow-up fixes and the stall fixes
merged: two full parallel runs passed 3,646 of 3,646, in 158 s and 96 s. tvOS
and macOS builds passed.

### Nested artwork redirect verification

At `d3f98bcf`, the iOS app/test build succeeded and the full parallel LumeTests
run passed all 3,652 tests (4,146 parameterized executions), with no failures or
skips, in 92 s on the iPhone 17 Pro simulator running iOS 27.0. SwiftFormat and
strict SwiftLint passed. Existing test/compiler warnings remain; the run also
reported priority inversions in the test-only projection-gate hold helpers.

Regression coverage includes mixed-case credential aliases, repeated encoding,
nested wrappers, relative and scheme-relative return URLs, userinfo, opaque
non-UTF8 query bytes, and excessive query size/depth. Signed CDN queries and
same-origin redirects retain their exact URL bytes. Bounds are eight decoding
passes per value, eight nesting levels and 64 KiB of cumulative query/decoding
work; exceeding a bound refuses the cross-origin hop rather than guessing.

Evidence: `/tmp/lume-nested-artwork-final-build.xcresult` and
`/tmp/lume-nested-artwork-tests.xcresult`. No physical-device checks or new
tvOS/macOS app builds were run for this focused follow-up. The fix remains on
`fix/audit-validation`, pending review/merge.
