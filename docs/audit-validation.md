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

## Deliberate boundaries and next measurements

The enhanced proxy remains optional. This pass does not alter provider catalogue
IDs, CloudKit schemas, viewing-identity policy or playback focus/navigation.
It does not inspect, move or change API secrets, and does not add `_NOTES` to Git.

Two adjacent areas merit dedicated validation rather than an unmeasured rewrite:

1. **Native playback redirects.** Initial playback URLs are origin-checked, but
   FFmpeg, VLC and AVFoundation own their subsequent HTTP exchanges. The artwork
   and WebDAV URLSession delegates do not govern those engines. A loopback
   cross-origin redirect contract test per engine should establish header/query
   forwarding before changing authenticated playback routing. This sweep does
   not claim those internals are protected by the artwork policy.
2. **Response-size enforcement before allocation.** Some readers reject oversized
   responses only after `data(for:)` has collected them; the accepted-size limit
   is not a peak-memory limit. A bounded streaming transport should be measured
   in Release for CPU, memory, cancellation and connection reuse before adoption,
   particularly for repeated metadata batches and artwork. The existing header-
   only stream redirect probe is already streaming and is not a full-body read.

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
