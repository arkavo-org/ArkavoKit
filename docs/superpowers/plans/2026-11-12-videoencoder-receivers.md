# VideoEncoder Receiver Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `VideoEncoder`'s file writing onto macOS 27's AVAssetWriter receiver API and remove 8 of its 10 pinned deprecation warnings (the receiver API has no real-time switch, so `expectsMediaDataInRealTime` stays). Keep the #44 rule that a sample the file doesn't take never sets the file's timeline.

**Architecture:**
- The video input is reached through an `AVAssetWriterInput.PixelBufferReceiver`, and each audio source through an `AVAssetWriterInput.SampleBufferReceiver`.
- Every append goes through `appendImmediately`. A `false` return counts as not ready, and a throw counts as rejected.
- Readiness is only known at the append now. So each append path saves the timeline state (the start time and the pause gap), and restores it on any exit that doesn't append the sample.

**Tech Stack:**
- Swift 6 on SwiftPM tools 6.4, warnings treated as errors
- AVFoundation, CoreVideo, CoreMedia (macOS 27 SDK)
- swift-testing

**Spec:** `docs/superpowers/specs/2026-11-12-videoencoder-receivers-design.md`

## Global Constraints

- Branch `fix/videoencoder-receivers`, from main 7cc8f35.
- No new compiler warnings. `python3 scripts/check-warnings.py <log>` must pass, with 8 pinned (6 NanoTDF, 2 `expectsMediaDataInRealTime`; see the Task 1 ruling).
- Never use the async `append`, only `appendImmediately`.
- Never call `startSession(atSourceTime:)` twice in a recording.
- The public API, the file format and streaming are unchanged.
- Run every build pipeline under `set -o pipefail`, so a failed build can't pass as a warning check.
- Nothing is pushed, and no PR is opened, without Paul's approval.

## Review Focus

1. **A refused first video frame followed by audio.** The audio is counted `beforeSession`, not written against a start that was never confirmed. Covered in Task 2, test 1.
2. **A late duplicate frame right after a resume.** It must not use up the pause gap. This is broken on main today. Covered in Task 2, test 5.
3. **A recording where every sample is refused.** The session started but no media was written, so `finishRecording()` must throw `RecorderError.noMediaWritten` and remove the file. Covered in Task 2, test 6.
4. **Pixel-buffer attributes vs. real capture buffers.** The tests feed 640×360 32BGRA IOSurface buffers. If the existing suites report `rejected`, or the writer fails, check the `CVPixelBufferCreationAttributes` from Task 1 first. Covered by the existing suites in Task 1, Step 5.
5. **An audio-only first sample whose retiming fails.** The same `defer` that covers the other exits rolls it back. No test feeds it, because a buffer that passes `CMSampleBufferIsValid` but has no timing can't easily be built. A reviewer should check that the `retimeFailed` return sits inside the `defer`'s scope.

---

### Task 1: Write through the receivers

**Files:**
- Modify: `scripts/warning-allowlist.txt`. Delete lines 4–5 (the VideoEncoder comment) and lines 7–16 (the 10 VideoEncoder entries).
- Modify: `Sources/ArkavoRecorder/VideoEncoder.swift`:
  - the properties (lines 54–57)
  - the `notReady` doc on `DroppedMedia.Counts` (line 26): checked at the append now, after the other reasons
  - setup and start in `startRecording` (lines 250–316)
  - `finishRecording` (lines 370–432)
  - `appendVideoToFile` (lines 529–604) and `appendAudioToFile` (lines 660–748)
- Modify: `Tests/ArkavoKitTests/DroppedMediaTests.swift:70-72`. The comment there says an unready frame never reaches the order check. That is now false: the order check runs first, and an unready frame never sets `lastVideoTimestamp`. Keep the tolerant assertion.
- Commit with it: the spec and this plan.

**Interfaces:**
- Produces, as private state on `VideoEncoder`:
  - `videoReceiver: AVAssetWriterInput.PixelBufferReceiver?`
  - `audioReceivers: [String: AVAssetWriterInput.SampleBufferReceiver]`
  - These replace `videoInput`, `audioInputs` and `pixelBufferAdaptor`. Audio-only mode is `videoReceiver == nil`.

- [ ] **Step 1: Make the warning check expect the migration.** Apply the allowlist edit, then run:

  ```bash
  set -o pipefail; swift package clean && swift build --build-tests 2>&1 | tee .build/warnings.log && python3 scripts/check-warnings.py .build/warnings.log; echo "exit $?"
  ```

  Expected: the build succeeds, then the check exits 1, reporting the 10 VideoEncoder warnings as unexpected.

- [ ] **Step 2: Set up the receivers.**
  - Video: `assetWriter.inputPixelBufferReceiver(for: input, pixelBufferAttributes: CVPixelBufferCreationAttributes(pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA), size: CVImageSize(width: videoWidth, height: videoHeight), compatibility: [.metalTexture]))`
  - Audio: `assetWriter.inputReceiver(for: newInput)` for each source, with the same settings and `source` metadata as now.
  - Remove `expectsMediaDataInRealTime` and `assetWriter.add(_:)`.
  - Replace `guard assetWriter.startWriting()` with `do { try assetWriter.start() } catch { … throw RecorderError.encodingFailed }`, keeping the log lines.

- [ ] **Step 3: Append through `appendImmediately`.**
  - Remove both `isReadyForMoreMediaData` checks, along with the comment that the readiness check runs before the session starts.
  - Video: `try receiver.appendImmediately(CVReadOnlyPixelBuffer(unsafeBuffer: pixelBuffer), with: adjustedTimestamp)`
  - Audio: `try receiver.appendImmediately(CMReadySampleBuffer(unsafeBuffer: finalBuffer))`
  - In both paths, `false` adds 1 to `notReady` and returns. A thrown error adds 1 to `rejected`, logs it with the existing writer-error lines, and returns.
  - The session still starts as it does today. Task 2 adds the rollback.

- [ ] **Step 4: Finish through the receivers.** In both finishing branches of `finishRecording`, replace `markAsFinished()` with the receivers' `finish()`. Clean up by setting `videoReceiver = nil` and `audioReceivers = [:]`.

- [ ] **Step 5: Verify.** Run:

  ```bash
  set -o pipefail; swift package clean && swift build --build-tests 2>&1 | tee .build/warnings.log && python3 scripts/check-warnings.py .build/warnings.log && swift test --skip-build --disable-xctest --filter "DroppedMediaTests|PauseResumeTests|RecorderTimingTests|EmptyRecordingTests|RecordingAudioTrackTests|OverlappingRecordingTests|RecordingSessionStopTests|RecordingMetadataTests"
  ```

  Expected:
  - The check prints "no unexpected warnings (8 pinned)".
  - Every listed suite passes.

  If the `sending` hand-off of `pixelBuffer` fails to compile, wrap the frame once at the top of `encodeVideoFrame`, and give the stream path the buffer through `withUnsafeBuffer`.

- [ ] **Step 6: Commit.**

  ```bash
  git add scripts/warning-allowlist.txt Sources/ArkavoRecorder/VideoEncoder.swift Tests/ArkavoKitTests/DroppedMediaTests.swift docs/superpowers/specs/2026-11-12-videoencoder-receivers-design.md docs/superpowers/plans/2026-11-12-videoencoder-receivers.md
  git commit -m "fix(recorder): write through AVAssetWriter's receivers, drop 10 pinned warnings"
  ```

### Task 2: A sample the file doesn't take leaves the timeline as it was

**Files:**
- Modify: `Sources/ArkavoRecorder/VideoEncoder.swift`:
  - the test seam
  - the rollback in both append paths
  - a `sessionStarted` comment: it now means only "session started"
- Create: `Tests/ArkavoKitTests/RefusedAppendTests.swift`

**Interfaces:**
- Consumes: Task 1's receivers and their `appendImmediately` call sites.
- Produces, internal on `VideoEncoder`:
  - `enum RefusalForTesting: Sendable { case notReady, failed }`
  - `func refuseAppendsForTesting(_ refusals: [RefusalForTesting])`
  - The next appends to the file, video or audio, take these in order, without reaching the writer. `.notReady` acts as `appendImmediately` returning `false`. `.failed` acts as it throwing `RecorderError.encodingFailed`.
  - Backed by a private queue, documented like `finishingHookForTesting`.

- [ ] **Step 1: Add the seam.** Consult it immediately before each `appendImmediately` call.

- [ ] **Step 2: Write the failing tests** in `RefusedAppendTests` (a swift-testing `struct`).

  Conventions:
  - Use `DroppedMediaTests.pixelBuffer()`, `AudioMixerTests.buffer(frames:value:pts:)` and `DroppedMediaTests.audioBufferTimes(_:)`.
  - Times use timescale 48000. A video frame is 1600 (30 fps), sent every 34 ms. An audio buffer is 960 frames, sent every 20 ms.
  - Add `static func videoSampleTimes(_ url: URL) async throws -> [CMTime]`. It reads the video track through `AVAssetReaderTrackOutput(track:outputSettings: nil)` via `outputProvider`, and returns each `presentationTimeStamp` where `sampleCount > 0`, in file order.
  - Finish with `_ = try? await encoder.finishRecording()` unless a test says otherwise.

  The tests:

  1. `refusedFirstVideoFrameDoesNotSetTheStart`
     - Setup: `VideoEncoder(quality: .performance)`, video plus `["microphone"]`, then `refuseAppendsForTesting([.notReady])`.
     - Feed, in order:
       1. A frame at 48000.
       2. An audio buffer at 48800.
       3. Frames at `24000 + i * 1600`, for i = 0…8.
     - Expect:
       - `video.notReady >= 1`
       - `video.beforeStart == 0`
       - `audio.beforeSession == 1`
       - `videoSampleTimes(url).first == .zero`
  2. `refusedFirstAudioSampleDoesNotSetTheStart`
     - Setup: audio only, `["microphone"]`, `[.notReady]`.
     - Feed a buffer at 48000, then buffers at `24000 + i * 960`, for i = 0…8.
     - Expect:
       - `audio.notReady >= 1`
       - `audio.beforeStart == 0`
       - `audioBufferTimes(url).first?.pts == .zero`
  3. `failedFirstVideoFrameDoesNotSetTheStart`
     - The same as test 1, with no audio source or audio buffer, and `[.failed]`.
     - Expect:
       - `video.rejected == 1`
       - `video.beforeStart == 0`
       - first video time `.zero`
  4. `refusedFirstFrameAfterAResumeLeavesNoGap`
     - Setup: video only.
     - Feed frames at `48000 + i * 1600` (i = 0…4).
     - Let `before = 5 - droppedMedia.video.total`, and `#require(before > 0)`.
     - Call `pause()`, `resume()`, `refuseAppendsForTesting([.notReady])`.
     - Feed frames at `144000 + j * 1600` (j = 0…4), then finish.
     - Let `times = videoSampleTimes(url)`, and `#require(times.count > before)`.
     - Expect `times[before] == times[before - 1] + CMTime(value: 1600, timescale: 48000)`, with the message `"\(times) \(droppedMedia)"`.
     - This holds however many frames the writer itself refuses. A frame that follows the last written one closes the gap exactly there.
  5. `lateDuplicateAfterAResumeLeavesNoGap`
     - The same as test 4, except:
       - no seam
       - after `resume()`, re-send the frame at `48000 + 4 * 1600` before the resumed frames
     - Expect:
       - the same `times[before]` equality
       - `dropped.notReady > 0 || dropped.outOfOrder == 1`
  6. `aRecordingWhoseEverySampleIsRefusedIsEmpty`
     - Setup: audio only, five `.notReady`, then five buffers.
     - Expect `finishRecording()` to throw `RecorderError.noMediaWritten`, and no file at `url`.

- [ ] **Step 3: Run the tests to see them fail.**

  ```bash
  set -o pipefail; swift build --build-tests && swift test --skip-build --disable-xctest --filter RefusedAppendTests
  ```

  Expected:
  - Tests 1–3 FAIL on `beforeStart`: 9, because the follow-ups fall before the stale start. Test 1 also fails on `beforeSession == 0`, and on its first time (no video track).
  - Test 4 FAILS: `times[before]` is 9600 rather than 8000 when `before == 5`.
  - Test 5 FAILS for the same reason: `times[before]` is 96000, a whole pause late.
  - Test 6 passes. It pins the empty-recording path, which now runs after `startSession`.

- [ ] **Step 4: Add the rollback.**
  - In both append paths, right after the `.writing` check, save `startTime`, `resumePending` and `totalPausedDuration`.
  - Then `var appended = false` and `defer { if !appended { restore the three } }`.
  - Set `appended = true` only after `appendImmediately` returns `true`.
  - Change the start block to set `startTime` when it is nil, and to call `startSession(atSourceTime: .zero)` only when `!sessionStarted`.
  - Keep no `await` between saving and restoring.

- [ ] **Step 5: Run the tests to see them pass.**

  ```bash
  set -o pipefail; swift build --build-tests && swift test --skip-build --disable-xctest --filter "RefusedAppendTests|DroppedMediaTests|PauseResumeTests|RecorderTimingTests|EmptyRecordingTests"
  ```

  Expected: all pass.

- [ ] **Step 6: Commit.**

  ```bash
  git add Sources/ArkavoRecorder/VideoEncoder.swift Tests/ArkavoKitTests/RefusedAppendTests.swift
  git commit -m "fix(recorder): a sample the file doesn't take leaves its start and pause gap as they were"
  ```

### Task 3: Verify and run the hang check

**Files:** none changed. The results go in the PR body draft.

The harness is `/private/tmp/claude-502/-Users-arkavo-Projects-ArkavoKit/5272df39-c648-4617-ab02-54ffe552d2ba/scratchpad/hang-runs.sh <package dir> <label> <runs>`.
- It builds the tests.
- It runs `swift test --skip-build --disable-xctest` the given number of times on the normal pool, then the same number with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`.
- It kills any run past 300 s.
- It writes one line per run (exit code, time, the swift-testing result line), then `DONE`, to `<scratchpad>/hang-<label>/summary.txt`.

The baseline already ran on main 7cc8f35 (`hang-before`): no hangs. With the strict pool, 6 of 8 runs failed `ComposedPreviewTests.swift:214`.

- [ ] **Step 1: Run the full check.**

  ```bash
  set -o pipefail; swift package clean && swift build --build-tests 2>&1 | tee .build/warnings.log && python3 scripts/check-warnings.py .build/warnings.log && swift test
  ```

  Expected:
  - The check prints "no unexpected warnings (8 pinned)".
  - Every suite passes.
  - Report the actual skip counts. The known conditional skips are the RTMP test, two FairPlay tests that need `ARKAVO_TOKEN`, and the Secure Enclave test.

- [ ] **Step 2: Run the harness on the branch.** Run it with `/Users/arkavo/Projects/ArkavoKit after 8`. Expected: `hang-after/summary.txt` ends with `DONE`.

- [ ] **Step 3: Compare with `hang-before`.**
  - No hang on either side means the warnings-hang hypothesis is untested locally. Report any new failure on the branch.
  - Report the `ComposedPreviewTests` strict-pool failure as a separate lead.
  - If the branch hangs, report that the migration introduced or exposed it, with the stalled tests.

- [ ] **Step 4: Ask Paul before pushing or opening the PR.**
