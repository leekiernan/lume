# Restoring LumeEngine

Recorded 2026-10-06. LumeEngine was removed in commit `e768c118`
(`refactor(player): remove LumeEngine dependency and integration`) on
`refactor/remove-lume-engine`. The commit, rather than the branch name, is the
durable recovery reference: branch deletion after merge does not remove it.

## Why it was removed

The device evaluation did not establish an advantage over KSPlayer. LumeEngine
repeatedly failed to open provider HLS streams because of segment-extension checks
and TLS/I/O failures; KSPlayer then played those streams successfully. The extra
engine and separate FFmpeg binary added download size, settings, maintenance and
a sibling-repository requirement. No real 1080i stream was available to evaluate
its proposed deinterlacing advantage. Restoration should address a demonstrated
playback gap, not merely add another fallback.

## Recovery references

- Inspect the removal: `git show e768c118`.
- Inspect any original file: `git show e768c118^:<path>`.
- For an immediate reversal, create a new branch from the current main and
  `git revert e768c118`. Do not reset main or overwrite unrelated later changes.
  After intervening player changes, use the old files as reference and port the
  integration selectively rather than assuming a clean revert is still correct.
- The sibling `../LumeEngine` repository was not deleted or modified. Its clean
  local checkout at removal was `54ea60bc40da23a88e7d88ff87d9734f6cee05b3`, tagged
  `v0.3.0`. The removed release workflow separately defaulted to `v0.3.1`.
  These are historical references, not a claim that both versions were validated
  against the app. Re-check the engine API, toolchain and binary artifacts.
- Historical estimates were 49 MB for a Debug simulator engine framework and
  291 MB for its cached FFmpeg artifact, not compressed release-download savings.
  Existing shared caches were retained; task-only verification caches were removed.

## What must come back together

1. **Dependency and project overrides.** Restore the local package reference,
   product, link/embed entries and embedding phase. Remove these retired IDs from
   `Scripts/fork-project-overrides.json` so future upstream intake does not strip
   the restored engine:
   `C6AA10012FDD00010000AA01`, `C6AA10022FDD00010000AA02`,
   `C6AA10032FDD00010000AA03`, `C6AA10042FDD00010000AA04`,
   `C6AA10052FDD00010000AA05`. Follow the fork-project apply/capture/check workflow.
2. **App integration.** Recover the `LumeEngineCoordinator*`,
   `LumeEngineEngineView*`, `LumeEngineControlsOverlay`, `SubtitleCueModel` and
   `LumeEngineSettingsViews` files. Restore full-screen and Multi-View dispatch,
   Now Playing conformance, options/presets/storage keys, and platform settings
   links. Reuse the current shared controls, retry, audio-session, navigation,
   language and PiP helpers; do not resurrect superseded copies of their behavior.
3. **Preferences.** Restore the raw value `lumeEngine`, appended last in
   `PlayerEngineKind`, keeping KSPlayer as default. Existing raw priority strings
   were ignored, not destructively rewritten by this removal. An untouched old
   string can therefore reactivate its previous LumeEngine position when the
   case returns; newly saved three-engine orders will append it last. Decide
   deliberately whether old opt-ins should reactivate, and test both paths.
   Old `player.lume.*` UserDefaults keys were left inert, not cleared.
4. **Tests, localization and setup.** Update the three-engine assertions and
   retired-engine migration tests to reflect the restoration policy. Restore
   the 16 deleted engine-only catalog entries, contributor/agent instructions,
   and release workflow sibling checkout with an explicitly validated engine ref.
   Historical QoE records were retained and need no migration.

## Acceptance checks before shipping again

- Demonstrate the playback advantage and resolve the observed provider startup
  failures, including unusual HLS segment/key URLs and TLS handling.
- Verify startup fallback, terminal retry stopping, Try Again, seek/scrub controls,
  teardown, rapid stream changes, Multi-View, audio/subtitles, PiP and Now Playing
  against the current shared lifecycle. Retry policy remains app-owned.
- Run LumeTests on a supported iOS simulator, strict format/lint and translations;
  build the supported platforms and confirm the correct engine/FFmpeg artifacts
  are embedded. Measure release-size impact rather than reusing Debug estimates.
- Device-test the actual problematic streams. If interlacing is the justification,
  include a real 1080i stream and compare sustained motion/thermal behavior.

Broader historical findings remain in the local `_NOTES/video-engines.md`.
