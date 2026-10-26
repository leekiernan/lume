# Chromecast: scope (not implemented)

Status: scoped only, no code. Upstream shipped Google Cast for iOS and iPadOS in
`fbebcd2a`, followed by `692aa3ef` (MPEG-TS hint for Xtream live HLS),
`ab2269f7` (warn when no audio track will play on the receiver) and `05eecb38`
(Arabic strings). That is about 7,700 lines across 56 files, roughly half of
them tests. This note records what an adoption would take in the fork, so the
work can be picked up later without re-reading upstream.

## What it does upstream

- iPhone and iPad only. macOS, tvOS and visionOS keep AirPlay alone.
- One cast button in the player opens a lume-built device sheet with an
  AirPlay row (free) and Google Cast devices (Pro).
- Plays on Google's Default Media Receiver; the phone becomes a remote
  (play/pause, skip, scrub, volume, previous/next item, lock screen).
- The local engine is torn down while casting, so single-connection accounts
  free their slot. If the receiver can't load the stream, the cast ends and
  playback resumes locally at the same position.
- Closing the player keeps the cast running, with a mini-controller above the
  tab bar.
- Progress is committed at cast boundaries only, and cast sessions are left
  out of `PlaybackQoE` and the review-prompt health checks.

## Fit with the fork

The seam already exists: `Lume/Services/Player/CastService.swift` observes
the AirPlay route and names a `CastProvider` seam for Google Cast (issue #103).
`AirPlayRouteButton` is the button upstream grows into the cast button.

Upstream's pieces, and what each means here:

| Upstream | Fork action |
| --- | --- |
| `GoogleCastProvider` (only file importing the SDK, `#if os(iOS) && canImport(GoogleCast)`) | Port as is. |
| `CastProvider` / `CastService` changes, `CastStatusMapping`, `CastMediaRequest` | Port; pure and stub-tested. |
| `CastStreamResolver` (Xtream `.m3u8` preference, rejects header-auth, downloads, recordings) | Port; check against the fork's `PlayableMedia` and `StreamRedirect`. |
| `PlayerCastSession`, `FullScreenPlayerView+Cast` (casting as a host state, not a `PlayerEngineKind`) | Port the idea; rewire to the fork's three engines (no LumeEngine) and `PlayerChromeMachine`. |
| `CastProgressCommitter`, `WatchProgressWriter` changes | Rewrite against the fork's `WatchProgressWriter` / `WatchProgressBuffer` and `TrackerMutationQueue`, not upstream's `WatchedServicesSync`. |
| `CastDeviceSheet`, `CastPlaybackView`, `CastMiniController` + placement | Port; restyle with the fork's components and theme colour. |
| Audio-codec warning (`ab2269f7`) | Needs per-track codec on KSPlayer's clock; LumeEngine half doesn't apply. |
| `PremiumFeature` case | Add a `.chromecast` case and paywall entry. |
| 25 strings | Translate into the fork's 9 locales (Arabic not needed). |

## Platform and project changes

- SPM: `google-cast-ios-sdk` (upstream pinned 4.8.6, `GoogleCastDynamic`),
  linked into the Lume target only with `platformFilter = ios`; never into
  LumeTopShelf or LumeWidgets. Record the package and link phase change with
  `Scripts/fork-project.py capture`.
- `Info.plist`: Bonjour services `_googlecast._tcp` and
  `_CC1AD845._googlecast._tcp`, plus a Local Network usage string in
  `InfoPlist.xcstrings`.
- Don't configure the SDK under tests or previews. Start discovery only when
  the device sheet opens, so there's no Local Network prompt at launch.

## Rules to keep

- Never cast header-auth sources by moving a token into the URL.
- Never log receiver or content URLs, tokens or device names as public.
- macOS, tvOS and visionOS must build without the SDK.

## Size and risk

- Large: an engine-level host state, a new SDK dependency, Local Network
  permission and a persistent mini-controller. Plan it as its own branch of
  several commits (SDK and seam → session and remote → UI → progress → strings).
- Device-only verification: discovery, receiver playback and the lock-screen
  remote can't be tested on a simulator.
- Usage is expected to be low; AirPlay already covers Apple TV.
