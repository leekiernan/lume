# Test suite dependencies

The regular `LumeTests` suite should not require tracker credentials, provider
access or downloaded language models. Run it on the iOS simulator specified in
[AGENTS.md](../AGENTS.md). Some integration tests deliberately serve HTTP on
loopback: they exercise native playback, redirects, decompression and temporary
download files that a canned `URLProtocol` response cannot fully reproduce.
Those listeners are test fixtures, not calls to an external provider.

For additional macOS unit validation, the sandboxed test host must be allowed
to listen for those fixtures. Pass `ENABLE_INCOMING_NETWORK_CONNECTIONS=YES`
to that test invocation only; `Scripts/verify.sh quick` and `full` do this.
An ordinary Debug app has the client entitlement but no server entitlement,
so otherwise `NWListener` fails with POSIX `Operation not permitted` before
the test reaches its mock response. Do not add incoming access to the shipping
entitlements to accommodate tests.

```sh
xcodebuild test -quiet -project Lume.xcodeproj -scheme Lume \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/lume-dd-mac-tests \
  -clonedSourcePackagesDirPath /Users/lee/Library/Developer/Lume-SharedSPM \
  -collect-test-diagnostics never -only-testing:LumeTests \
  ENABLE_INCOMING_NETWORK_CONNECTIONS=YES COMPILER_INDEX_STORE_ENABLE=NO
```

Dynamic Type growth/touch-target rendering checks run on iOS/visionOS only:
macOS ignores that font-scaling environment and intentionally uses compact
pointer controls. Shared layout checks without that requirement remain portable.

Redirect policy units inject a `URLSession` and a controlled deadline. The
production four-second deadline stays unchanged. Cache launch-delay and EPG
cancellation tests similarly release explicit barriers instead of assuming a
background task will run within a fixed sleep. Barrier tests have a five-minute
failure backstop; this is not a performance target.

## Apple embedding integration probe

`TextEmbedderTests` injects `SentenceEmbeddingModel` to verify document forwarding,
Double-to-Float conversion, missing vectors, short-document preference, vector
space dimensions and unavailable-model handling. It does not claim to measure
the semantic quality of Apple's model. Production still discovers Apple's
`NLEmbedding` through the same default factory and bounded retries.

`SystemEmbeddingIntegrationTests` preserves the real Nemo/Toy Story/Godfather
genre comparison. It is explicitly disabled in the default suite because
simulator runtimes do not necessarily include the English sentence model.

To run it in Xcode:

1. Choose a test destination with Apple's English sentence assets installed.
2. Edit Scheme -> Test -> Arguments. Disable inherited Run arguments if needed
   and add the environment variable `LUME_TEST_SYSTEM_EMBEDDINGS` with value `1`.
3. Run `SystemEmbeddingIntegrationTests` from the Test navigator.
4. Remove the variable after the probe so routine units stay asset-independent.

With the probe enabled, missing sentence assets fail explicitly with
`modelUnavailable`; they are not treated as successful semantic validation.
The probe prepares the sentence backend without requesting downloads. If the
contextual model can also be discovered, it verifies that the two backends have
different space IDs and document preferences; it does not request contextual
assets or claim that comparison ran when discovery was unavailable.

A default run therefore reports one intentionally disabled system-model test.
Network policy and adapter units must still pass; do not classify their errors
as expected environment failures or increase deadlines to hide them.

## Verification on 2026-11-01

Both full suites passed on branch `fix/test-suite-failures`:

| Destination | Passed tests | Passed executions, including parameters | Failed | Intentionally disabled |
| --- | ---: | ---: | ---: | ---: |
| iPhone 18 Pro simulator, iOS 27.2 | 3,888 | 4,475 | 0 | 1 system-model probe |
| macOS 27.2, arm64, incoming access enabled for test build | 3,866 | 4,450 | 0 | 1 system-model probe |

The macOS total excludes the iOS/visionOS Dynamic Type checks. These counts
are verification results, not an allowance for a standing failure baseline.
Changed Swift files passed strict SwiftLint and SwiftFormat; shell syntax,
documentation links and whitespace checks also passed.

Result bundles retained locally:

- `/tmp/lume-suite-failures-ios-full.xcresult`
- `/tmp/lume-suite-failures-mac-full.xcresult`

The opt-in model probe and physical-device checks were not run.
