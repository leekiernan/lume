# Typed metadata boundaries

The app's domain values are separate from provider payloads and SwiftData's
storage columns. Wire DTOs remain tolerant of missing fields. Normalize them
once before use; never make a view guess a numeric scale, unit or ID namespace.

## Domain and storage

| Meaning | Domain value | Storage mapping |
| --- | --- | --- |
| TMDB title, person, collection or genre ID | Namespace-specific `TMDBID`, `TMDBTitleReference` | Existing integer columns |
| IMDb title ID | `IMDbTitleID` | Existing string column |
| Rating | `RatingScore` with explicit scale | Existing provider columns; numeric external-rating JSON |
| Runtime | `MediaRuntime`, seconds internally | Existing seconds column |
| Release | `ReleaseDate`, year or calendar-day precision | Existing date string |
| TMDB artwork | `TMDBImagePath`, family-specific rendition enums | Existing path columns |
| Genres and certification | `TitleGenre`, `TitleCertification` | Optional JSON plus existing searchable/display columns |
| Effective TMDB identity source | `TMDBAssignment` | Optional JSON |

Typed computed properties map into and out of scalar storage. Query predicates
continue to use the scalar columns. A change to a provider's genre/certification
label supersedes the associated structured cache rather than exposing stale IDs.

`TMDBTitleDetails` is the normalized response shared by proxy and direct TMDB
delivery. It carries its movie/series identity, validated artwork, score,
runtime, genres, certification country, people, similar-title references and
movie collection. Applying a different identity is rejected. Proxy capability,
freshness and device fallback policies are unchanged.

## Identity provenance and withdrawal

Catalogue assignments can replace the effective identity. Provider detail and
device search assignments fill a missing identity. Withdrawal clears metadata
only when the catalogue is known to own the assignment. A sparse catalogue does
not withdraw a detail-supplied or device-searched ID.

Legacy movie catalogue provenance can be established from the former catalogue
column. Legacy series provenance is ambiguous and is not guessed: the next
nonempty catalogue response records its source. A corrected identity invalidates
its detail/index cache but preserves watch state, favorites, downloads and
episodes. Background sync hides stale cast; the detail-owned context replaces
the relationships safely.

Shared fields filled by TMDB have field-typed restore points. Numeric values are
not formatted as strings. Restoration only applies if a field still equals the
value TMDB wrote, so subsequent provider edits survive.

## Other boundaries

Unknown persisted content/category discriminators are unsupported, never movie
or live-TV defaults. Reconcile and profile export preserve unsupported records.

Sports wire evidence is converted to `ValidatedSportsEvidence`: timed programme
matches and untimed channel suggestions are different cases. Timed matches have
a source, pairing kind and valid programme interval. Raw evidence text stays out
of player/detail surfaces because it can contain scores. Local restrictions,
user picks and fallback matching remain device decisions.

`PlaybackLocator` distinguishes direct URLs from deferred portal commands using
the playlist source. Playback retains file/RTSP/UDP and other engine schemes;
the http(s)-only image rule is not a playback restriction. Missing direct URLs
on non-Xtream sources do not fall through to Xtream credential-built URLs.
Catch-up remains VOD playback with a live-channel content reference.

## Store compatibility

The schema additions are optional metadata fields; no store reset or user-state
migration is required. Old ratings and fallback JSON are mapped on read and
rewritten in typed form on the next write. Invalid cached metadata can be
refetched. No change is made to catalogue IDs, CloudKit record keys, profiles,
watch history, favorites or credentials.

Tests cover invalid numeric bounds, custom Codable validation, typed storage
round trips, identity mismatch/withdrawal, unknown discriminators, sports
evidence combinations and playback locator source handling.
