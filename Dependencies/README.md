# Playback packages

KSPlayer, FFmpegKit, FFmpegBuild, LibDovi and VLCKit aren't cloned by SwiftPM.
Their Git histories hold years of superseded binaries: FFmpegKit's alone is
853 MB. Instead, `Scripts/playback-packages.py` downloads each one's snapshot
at the commit pinned in
[`playback-dependencies.json`](../Scripts/playback-dependencies.json), with no
history. VLCKit's frameworks come from VideoLAN's published zip.

The script then:

1. Trims the frameworks to what Lume builds: ARM64 slices for iOS, macOS, tvOS
   and visionOS, device and simulator.
2. Proves every retained ARM64 slice is upstream's byte for byte. Nothing is
   rebuilt.
3. Drops the dSYMs.

   One exception: FFmpegBuild's and LibDovi's macOS device slices stay whole,
   Intel included (`untouched_platforms`). They link into `LumeAetherBridge`,
   a dynamic Swift package product. A Mac archive builds package products for
   both architectures whatever the app's `ARCHS = arm64`, so that link needs
   x86_64. The cost is about 30 MB.
4. Checks the whole package against the content hash in the lock.

Nothing is hosted by us.

Each folder here is a gitignored symlink into
`~/Library/Developer/Lume-PlaybackPackages`. That store is shared by every
checkout and worktree on the Mac, and holds about 1.2 GB.

```sh
/usr/bin/python3 Scripts/playback-packages.py fetch   # Scripts/setup.sh runs this
```

Run it after cloning, in a new worktree, and whenever the lock changes. It only
downloads what the store lacks. Until it has run, Xcode reports the
`Dependencies/…` packages as missing.

## How the packages are wired

- **KSPlayer and VLCKit** replace the project's former remote references.
  VLCKit's manifest is the only one rewritten: its one `binaryTarget` points at
  the trimmed local framework instead of VideoLAN's zip.
- **FFmpegKit, FFmpegBuild and LibDovi** are local packages. They replace the
  dependencies of the same name that KSPlayer and AetherEngine declare.
  - Both Xcode's root package references and `LumeAetherBridge` must list them;
    a nested local dependency alone doesn't replace a remote pin in Xcode.
  - A local package has no version, so SwiftPM never checks it against those
    requirements. `Scripts/check-playback-dependencies.py` does. The pre-commit
    hook runs it whenever the engine pin or the lock changes.
- **AetherEngine and SMBClient** stay ordinary remote packages. Their histories
  are small.

## Debug symbols

Day-to-day builds never need dSYMs. When Xcode archives Lume, the "Fetch
playback archive symbols" build phase runs `playback-packages.py symbols`. For
the archive's platform, it:

1. downloads the upstream source again;
2. extracts only that platform's dSYMs;
3. thins them to ARM64;
4. checks their UUIDs against the frameworks in the build;
5. copies them into the archive.

Only FFmpegBuild and VLCKit ship dSYMs. VLC's come from its 910 MB zip, so an
archive downloads that once per platform.

## Upgrading

1. In `Scripts/playback-dependencies.json`, change the package's `revision` and
   `version`, plus VLCKit's `binaries` URL and SHA-256 if it changed.
   - For FFmpegBuild or LibDovi, pick a version AetherEngine's pinned manifest
     accepts.
   - For FFmpegKit, pick one KSPlayer's manifest accepts.
2. Run `/usr/bin/python3 Scripts/playback-packages.py pin --package <Name>`.
   This rebuilds the package, records its new `tree_sha256` and relinks it.
3. Run `Scripts/check-playback-dependencies.py`.
4. Build macOS, iOS, tvOS and visionOS, and run the macOS unit suite. For a
   library version change, include device playback checks through the normal
   review process.
5. Commit the lock.

To change what is kept (the `distribution` policy), edit it and `pin` every
package.

`playback-packages.py prune` lists store entries the current lock doesn't use.
Add `--apply` to delete them, but only once no other branch or worktree needs
them.

```sh
python3 Scripts/test-playback-packages.py
python3 Scripts/test-check-playback-dependencies.py
python3 Scripts/test-fork-project.py
python3 Scripts/check-playback-dependencies.py
python3 Scripts/fork-project.py check
```
