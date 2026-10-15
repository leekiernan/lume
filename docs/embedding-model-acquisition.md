# Embedding model acquisition

## Reproduction

On the iOS 27.0 simulator, a standalone Swift executable calling
`NLEmbedding.sentenceEmbedding(for: .english)` reproduced the failure outside
Lume and Swift Testing: the initial lookup returned nil, while subsequent
lookups produced a revision-1 sentence model with 512-dimensional vectors.
Some fresh processes returned nil several times before succeeding.

The failure occurred on both main and background threads. Waiting before the
first lookup or querying supported revisions did not prevent it. The OS can
advertise the revision while acquisition still returns nil. One physical
Apple TV running tvOS 27.2 successfully acquired its model on launch; the
simulator reproduction is not proof of the same fault on hardware.

Nil means the model was not acquired, not that the device can never support it.
The old service treated this as permanent unavailability for the process.

## Recovery policy

`EmbeddingModelAcquisition` performs one initial lookup and at most three
retries, separated by asynchronous waits of 100 ms, 250 ms and 1 s. The 1.35 s
is the total backoff, not a timeout on Apple's synchronous model lookup itself.
There is no busy loop, asset request, word-model warm-up or backend fallback.

Cancellation is checked before lookups, after waits and before accepting a
model. Exhaustion returns no model and ends the current indexing pass as
interrupted. A later normal launch/sync kick can try again; there is no
self-rescheduling loop. Kicks still coalesce while a pass is running.

Both sentence and contextual factories use this acquisition policy. Backend
selection is unchanged: sentence on tvOS, contextual elsewhere, preserving
the existing vector-space identities. The contextual model's separate asset
preparation/download budget and unavailable state are unchanged.

No catalogue state, vectors or vector-space stamps are changed before a model
has been acquired. Existing watch history and metadata delivery are unaffected.

## Verification

Deterministic tests inject lookup outcomes and waits, checking immediate success,
repeated nils, exact attempt limits, later recovery and cancellation. Service
tests exercise actual `kick()` behavior with injected passes, including recovery
after exhaustion and coalescing. Real NaturalLanguage integration tests call
the same asynchronous factories as production, so cold-start recovery is not
implemented only in the tests.
