
# VideoEncoder on AVAssetWriter's receiver API

A small change: the approach and design were approved in conversation on 2026-11-12. This records them, plus the calls made since. Codex and Kimi reviewed a first draft; the rollback, the tests and the hang check below reflect what they found.

## Why

`VideoEncoder` writes recordings through AVAssetWriter API that macOS 27 deprecates:
- `add(_:)`
- `expectsMediaDataInRealTime`
- `AVAssetWriterInputPixelBufferAdaptor`
- `isReadyForMoreMediaData`
- `append(_:)`
- `startWriting()`

That is 10 of the 16 warnings pinned in `scripts/warning-allowlist.txt`. Paul wants the build free of warnings and suspects they are linked to the swift-testing hangs on CI. Moving to the receiver API removes the warnings.

## Goals

- Delete the VideoEncoder warnings and their allowlist entries. The NanoTDF entries stay.
  - **Found during implementation:** 8 of the 10 go. The two `expectsMediaDataInRealTime` warnings stay pinned. The receiver API has no real-time switch, and `appendImmediately` alone leaves the inputs offline. The writer then refuses video to interleave it with audio: after a pause, `PauseResumeTests` lost 25 of 30 frames on every run. The allowlist comment now says this.
- Each `DroppedMedia` counter keeps its meaning. Only the order of the checks changes: a sample with more than one reason to be dropped is now counted under a reason checked before the append (`beforeStart`, `outOfOrder`, `retimeFailed`), not under `notReady`.
- Keep the #44 guarantee: a sample the file doesn't take never sets the file's start.

## Non-goals

- The NanoTDF warnings. Removing them changes the NTDF wire format.
- Any change to streaming, public API or the file format.
- Fixing the CI hang directly. Whether this change affects it gets measured, not assumed.

## Anti-goals

- Frames that queue behind the encoder or are written out of order.
- Starting a session twice, or a file whose first sample isn't at zero.

## Approaches

1. **`appendImmediately` (chosen).**
   - A `false` return means the input isn't ready: today's `notReady` drop.
   - A throw means the input failed: today's `rejected`.
   - Nothing blocks, so frames keep their order.
   - The cost: readiness is known only once you try to append, after the session has started and the timeline has been worked out for that sample. That state has to be undone when the sample isn't taken.
2. **Async `append`.** It waits until the input is ready. Rejected: real-time capture would queue behind the encoder, the actor would be suspended mid-append, and frames could arrive out of order.
3. **Keep the deprecated API and leave the warnings pinned.** Rejected: Paul asked for the warnings to go.

## Design

**Setup**
- Video uses `assetWriter.inputPixelBufferReceiver(for:pixelBufferAttributes:)`. The attributes become `CVPixelBufferCreationAttributes`: 32BGRA, the encoder's width and height, `.metalTexture` compatibility.
- Each audio source uses `assetWriter.inputReceiver(for:)`, with the same settings and source metadata as now.
- The receiver calls add the inputs, so `add(_:)` goes. `expectsMediaDataInRealTime` stays (see Goals).
- The encoder keeps the receivers, not the inputs and adaptor. Audio-only mode becomes "no video receiver".

**Start:** `try assetWriter.start()` replaces `startWriting()`. A failure still throws `RecorderError.encodingFailed`.

**Append**
- Video sends `CVReadOnlyPixelBuffer(unsafeBuffer:)` through `appendImmediately(_:with:)`.
- Audio sends the retimed buffer as `CMReadySampleBuffer(unsafeBuffer:)` through `appendImmediately(_:)`.
- `false` counts `notReady`, and a throw counts `rejected`.

**A sample the file doesn't take leaves the timeline as it was (my call; the conversation covered only a refused first sample's start)**
- Each append path saves `startTime`, `resumePending` and `totalPausedDuration` once the writer is known to be writing. It restores them on every exit that doesn't append the sample:
  - `false`
  - a throw
  - `beforeStart`
  - `outOfOrder`
  - `retimeFailed`
- A `defer` keyed on "appended" does it, so the timeline is committed only by an append.
- This also closes two holes in today's code:
  - A late duplicate frame right after a resume uses up the pause gap. The frames that follow then land a whole pause late.
  - An audio-only first sample whose retiming fails still sets the start.
- `sessionStarted` stays outside the rollback, so `startSession(atSourceTime: .zero)` is called once. It now means "session started" only. `startTime == nil` means "no zero point yet", which also gates audio when there's video, `duration`, and `streamStartTime`.
- Saving, appending and restoring all run with no `await` between them, so no other actor call sees the unconfirmed state.

**Finish:** each receiver's `finish()` replaces `markAsFinished()`, in both branches that finish the file. `finishWriting()` and `cancelWriting()` are unchanged.

## Testing

**The warning check is the migration's red.** Removing the 10 entries first makes `scripts/check-warnings.py` fail. The migration turns it green.

**Refusal seam (my call)**
- An internal test seam makes the next appends act refused, as not ready or as failed, so those cases are deterministic. It is in the style of `finishingHookForTesting`.
- Each test asserts something the real writer can't break by refusing more samples itself. Either:
  - the counters, using a follow-up sample stamped *earlier* than the refused one; with a stale start it counts `beforeStart`, or
  - a position measured from the samples that were actually written.
- A red run, with the rollback taken out, has to fail on those assertions. The late-duplicate test also fails on today's code.

**Full verification**
- A clean `swift build --build-tests`, with `pipefail`.
- `check-warnings.py`, expecting 8 pinned.
- The full `swift test`, reporting the actual pass and skip counts.

**Hang check**
- Baseline on untouched main 7cc8f35: 16 runs of the swift-testing pass (188 tests), with a 300 s watchdog, produced no hangs.
  - Normal cooperative pool, 8 runs: all passed, in about 21 s each.
  - `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`, 8 runs: 6 failed, all on the same test, `ComposedPreviewTests.swift:214`. It waited 15 s for a frame, which points to a blocked cooperative thread in the preview path, not in `VideoEncoder`.
- So the hang hypothesis can't be tested locally. The branch gets the same 16 runs, to show the migration adds no hang or new failure. The result is reported as "untested locally", not "fixed". The `ComposedPreviewTests` lead is reported separately.

## Left to the builder

- Wording of the seam and of the log lines.
- If frames come back `rejected` or the writer fails, suspect the new pixel-buffer attributes first. Their default `backing` hasn't been checked against the IOSurface buffers the tests feed.
