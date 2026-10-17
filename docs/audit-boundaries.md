# Audit boundaries and lifecycle ownership

This pass keeps the local catalogue and CloudKit schemas unchanged. Typed
snapshots and bounded operations sit over existing storage; there is no
permanent migration or replacement of provider-specific DTOs.

## Ownership and privacy

- `ProfileScope` combines the persisted viewer ID with a process-local generation.
  A retired player cannot save progress after a profile projection changes, even
  when the viewer switches away and back to the same profile. Resume hints are
  profile-scoped, and clearing history also clears those hints and records the
  existing clear-history intent.
- `ProfileProjectionGate` serializes synchronous viewer-state saves with the
  catalogue projection swap. It covers writes already underway, not just queued
  work. Scoped maintenance holds it one page at a time; model contexts stay with
  their existing owners, and no network call or suspension runs under the gate.
- Tracker sessions invalidate refresh and identity work before disconnecting.
  Remote revocation cannot clear a newer login, and mutation queues recheck their
  account after awaiting a token.
- Related-title selection applies hidden/parental restrictions before choosing a
  provider copy. Movie and series TMDB IDs are separate namespaces; the same
  integer in the other namespace is not a fallback match.
- `PlaylistConnection` validates source-specific runtime configuration without
  changing stored columns. Unknown sources cannot enter the Xtream sync or
  stream builders. Xtream path credentials are encoded as individual segments.
  Playback authentication is confined to the configured server origin. Display
  addresses omit credentials in userinfo, paths and queries.
- `ArtworkRequest` separates recognized media-server authentication from the
  image URL and keeps private cache keys opaque and account-isolated. Public
  images retain their existing cache identities, preserving offline artwork.
  An explicit account scope survives token rotation; legacy URL-only callers use a credential
  fingerprint rather than share private images across accounts. Cross-origin
  redirects strip authentication headers; external Plex artwork does not acquire
  the server's token in the first place.
- Authenticated Top Shelf artwork is materialized by the app. Shared snapshots
  carry app-rendered image files, not tokens; uncached images can arrive in a
  subsequent export. The export ownership/visibility gates remain in force.
  Arbitrary provider-supplied file URLs are still not accepted by image loaders.

Legacy/local provider artwork columns can still contain authenticated URLs.
This is an explicit compatibility boundary, not a secret-storage migration:
recognized authentication is lifted into headers at transport time and removed
from shared snapshots. Unknown provider-specific URL formats are not guessed at.

## Stateful operations

- `DownloadLifecycle` owns each URLSession attempt through queued, running,
  finishing and retired states. Cancellation promotes queued work immediately;
  late callbacks cannot settle a replacement. Attempts use distinct filenames,
  and background recovery plus status writes share an ordered persistence lane.
- `PlaybackStartupSupervisor` owns the startup deadline and terminal failure
  latch across KSPlayer, VLC, AVPlayer and multi-view. First-frame evidence stays
  in `PlaybackStartTracker`; reconnect budgets, engine-specific resume handling,
  clock-drift detection and UI projections retain their existing mechanisms.
  Proof arriving before a representable's appearance hook is retained.
- Redirect probing uses native streaming, cancels after reading the response
  headers and does not collect media data. Range-ignoring servers therefore cannot
  turn a probe into a full-film download. The shared session keeps its connection
  pool; no custom response-delegate lifecycle is needed.

## Bounded work

- `CatalogMaintenance` uses lexical keyset pages and a fresh background context
  per page. Saving batches from a single huge fetch did not release its hydrated
  objects. Maintenance rechecks cancellation and viewer ownership between pages
  and before saves; language invalidation records success only after completion.
- Indexer chunks read their source map once and batch-fetch movie/series
  writeback rows. Identity and account checks still run after network/busy waits.
  Hidden-category read failures no longer become an empty restriction set.
- Bulk episode watched/unwatched actions mutate episodes once and derive series
  recency once, preserving resume hints and clear-history ledgers.
- Sports cache I/O runs on a serial actor. The UI coalesces pending writes and
  does not replace newer in-memory data with an older disk hydration.
- Sports schedule results retain their query window and success/failure outcome.
  Successful empty windows withdraw obsolete fixtures; failed windows retain
  their last good data. Day refreshes use bounded league workers. ESPN schedule,
  roster and standings requests propagate failure; optional detail reads can
  still degrade gracefully.

## Compatibility and verification

Provider imports use the shared TMDB assignment policy, including provenance and
invalidation when IDs change or are withdrawn. Device TMDB, ratings and sports
fallbacks remain optional enhancements: no enhanced proxy is required.

Regression coverage exercises retired operations, tracker disconnect races,
restriction-aware related rails, TMDB namespaces, redirect body avoidance,
download attempts/recovery, maintenance page boundaries, bulk history, sports
cache/window outcomes, typed source configuration, artwork authentication and
export privacy, and player deadline/failure ownership.

Physical-device checks should include player open/resume/source-switch/retry,
download cancel/retry, profile changes, offline sports warm-up, and authenticated
media-server artwork in Top Shelf. They complement simulator tests and builds;
they are not a prerequisite for the engineering handoff.

Verification on 17 October 2026 passed 3,512 unit tests across 500 suites on an
iPhone 17 Pro simulator running iOS 27. This includes the final early-frame
startup and profile-projection refinements. The iOS test build, native tvOS and
macOS builds, and the formatting/lint commit hooks passed. UI automation and
physical-device checks were not run for this pass.

No performance benchmark is claimed here: query and memory improvements follow
from bounded fetches, fewer lookups and releasing each page's context, not a
Debug timing comparison.
