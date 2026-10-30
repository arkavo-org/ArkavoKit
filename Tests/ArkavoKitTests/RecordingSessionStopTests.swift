import Testing
import AVFoundation
import Foundation
import os
@testable import ArkavoRecorder

/// A stop that fails still ends the recording: the session must not keep reporting
/// that it is recording and routing frames to a finished encoder.
///
/// Serialized: each test opens real hardware encoder sessions, an asset writer for the file and
/// a compression session for the stream. Run side by side, they exceed what the media engine
/// takes: encoding fails with `kVTSessionMalfunctionErr` (-17691), the writer with -11800, and the
/// stream-frame waits starve. That is a limit of the hardware, not frame pile-up, which the
/// 30 fps driver no longer allows (one frame in flight per session).
@MainActor
@Suite(.serialized)
struct RecordingSessionStopTests {
    @Test("A failed stop leaves the session not recording")
    func failedStopEndsRecording() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-stop-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        // Avatar mode with no avatar frames: needs no permissions and writes no media,
        // so finishing the file fails with noMediaWritten
        let session = try RecordingSession()
        session.enableDesktop = false
        session.enableCamera = false
        session.enableMicrophone = false
        session.enableAvatar = true
        try await session.startRecording(outputURL: url, title: "failed stop")
        #expect(session.isRecording)

        do {
            _ = try await session.stopRecording()
            Issue.record("stopRecording returned a URL for a recording with no media")
        } catch RecorderError.noMediaWritten {
        }

        #expect(!session.isRecording)
        #expect(session.duration == 0)
    }

    @Test("Stopping a recording keeps a sound the mixer was still buffering")
    func stopKeepsBufferedSound() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("buffered-sound-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        // Avatar mode needs no permissions; a stand-in clock source and the Muse voice feed the mixer
        let session = try RecordingSession()
        session.enableDesktop = false
        session.enableCamera = false
        session.enableMicrophone = false
        session.enableScreenAudio = false
        session.enableAvatar = true
        session.watermarkEnabled = false
        session.avatarTextureProvider = { createTestPixelBuffer(width: 1920, height: 1080, red: 0, green: 255, blue: 0) }
        let clock = FakeAudioSource(sourceID: "test-clock")
        let voice = FakeAudioSource(sourceID: "muse-voice")
        session.addMuseAudioSource(clock)
        session.addMuseAudioSource(voice)
        try await session.startRecording(outputURL: url, title: "buffered sound")

        // Half a second of a silent clock in real time, then a 20 ms tone and one more clock
        // buffer: when the recording stops, the tone is still short of the mixer's prefill.
        for _ in 0..<24 {
            clock.onSample?(Self.tone(frames: 1024, amplitude: 0))
            try await Task.sleep(for: .milliseconds(21))
        }
        voice.onSample?(Self.tone(frames: 960, amplitude: 8000))
        clock.onSample?(Self.tone(frames: 1024, amplitude: 0))
        _ = try await session.stopRecording()

        #expect(try await Self.peakAudioSample(in: url) > 2000)
    }

    @Test("Stream frames keep flowing while a recording stops, and none of them reaches the finished file")
    func streamFramesKeepFlowingWhileARecordingStops() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-continues-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        // From the moment the file stops taking frames, the avatar turns red.
        let finishing = OSAllocatedUnfairLock(initialState: false)
        let streamFrames = OSAllocatedUnfairLock(initialState: 0)
        let streamFramesWhileFinishing = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let encoder = VideoEncoder()
        await encoder.setFinishingHookForTesting {
            finishing.withLock { $0 = true }
            let before = streamFrames.withLock { $0 }
            try? await Task.sleep(for: .seconds(1))
            let after = streamFrames.withLock { $0 }
            streamFramesWhileFinishing.withLock { $0 = after - before }
        }
        let session = try Self.avatarSession(encoder: encoder)
        let green = try SolidFrame(red: 0, green: 255, blue: 0)
        let red = try SolidFrame(red: 255, green: 0, blue: 0)
        session.avatarTextureProvider = { finishing.withLock { $0 } ? red.buffer : green.buffer }
        try await session.startRecording(outputURL: url, title: "stream continues")
        try await session.startStreamingForTesting { _ in streamFrames.withLock { $0 += 1 } }
        try await Self.waitUntil { streamFrames.withLock { $0 } >= 10 }

        _ = try await session.stopRecording()
        let atStop = streamFrames.withLock { $0 }
        try await Self.waitUntil { streamFrames.withLock { $0 } >= atStop + 10 }
        let afterStop = streamFrames.withLock { $0 } - atStop
        await session.stopStreaming()

        // About 30 frames at 30 fps while the file finished, and the stream went on after it. A
        // stopped driver still shows a few: frames from before the stop leave the stream's encoder late.
        let whileFinishing = try #require(streamFramesWhileFinishing.withLock { $0 })
        #expect(whileFinishing >= 15)
        #expect(afterStop >= 10)
        let colors = try await Self.centerColors(in: url)
        #expect(!colors.isEmpty)
        #expect(colors.allSatisfy { $0.g > 150 && $0.r < 100 }, "a frame composed after finishing began reached the file")
    }

    @Test("A stream keeps the screen capture and audio feeding it when a recording stops")
    func streamKeepsItsSourcesWhenARecordingStops() async throws {
        let url = Self.outputURL("stream-sources")
        defer { try? FileManager.default.removeItem(at: url) }
        let live = try SharedSources()
        try await live.startRecordingAndStream(to: url)
        #expect(live.audio.isActive)

        _ = try await live.session.stopRecording()

        #expect(live.audio.isActive)
        #expect(await live.screenIsCapturing())
        await live.session.stopStreaming()
    }

    @Test("Stopping the recording, then the stream, releases the screen capture and audio")
    func stoppingTheRecordingThenTheStreamReleasesEverything() async throws {
        let url = Self.outputURL("record-then-stream")
        defer { try? FileManager.default.removeItem(at: url) }
        let live = try SharedSources()
        try await live.startRecordingAndStream(to: url)
        _ = try await live.session.stopRecording()

        await live.session.stopStreaming()

        #expect(!live.audio.isActive)
        #expect(!(await live.screenIsCapturing()))
    }

    @Test("Stopping the stream, then the recording, releases the screen capture and audio")
    func stoppingTheStreamThenTheRecordingReleasesEverything() async throws {
        let url = Self.outputURL("stream-then-record")
        defer { try? FileManager.default.removeItem(at: url) }
        let live = try SharedSources()
        try await live.startRecordingAndStream(to: url)
        await live.session.stopStreaming()
        // The recording still uses them.
        #expect(live.audio.isActive)
        #expect(await live.screenIsCapturing())

        _ = try await live.session.stopRecording()

        #expect(!live.audio.isActive)
        #expect(!(await live.screenIsCapturing()))
    }

    @Test("A stream that ends while the recording's file finishes releases the screen capture and audio")
    func streamEndingWhileTheFileFinishesReleasesEverything() async throws {
        let url = Self.outputURL("stream-ends-while-finishing")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = VideoEncoder()
        let live = try SharedSources(encoder: encoder)
        try await live.startRecordingAndStream(to: url)
        let session = live.session
        await encoder.setFinishingHookForTesting { await session.stopStreaming() }

        _ = try await session.stopRecording()
        await encoder.setFinishingHookForTesting(nil)

        #expect(!live.audio.isActive)
        #expect(!(await live.screenIsCapturing()))
    }

    @Test("A stream that starts while a recording's file finishes gets the screen capture and audio back")
    func streamStartingWhileTheFileFinishesGetsItsSources() async throws {
        let url = Self.outputURL("stream-starts-while-finishing")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = VideoEncoder()
        let live = try SharedSources(encoder: encoder)
        let session = live.session
        session.enableAvatar = false
        session.enableDesktop = true
        try session.startScreenPreview()
        let preview = await live.screenInput()
        // The recording's start waits for the first frame of its own screen capture.
        let start = Task { try await session.startRecording(outputURL: url, title: "finishing") }
        let deadline = ContinuousClock.now + .seconds(5)
        while await live.screenInput().map({ $0 === preview }) ?? true, .now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await live.screenIsCapturing())   // the first frame
        try await start.value
        // The recording's stop has already stopped the sources when the stream starts.
        await encoder.setFinishingHookForTesting { try? await session.startStreamingForTesting { _ in } }

        _ = try? await session.stopRecording()
        await encoder.setFinishingHookForTesting(nil)

        try await Self.waitUntil { live.audio.isActive }
        #expect(live.audio.isActive)
        #expect(await live.screenIsCapturing())
        await session.stopStreaming()
        #expect(!live.audio.isActive)
        #expect(!(await live.screenIsCapturing()))
    }

    @Test("A stream that starts while a recording's file finishes gets its cameras started again")
    func streamStartingWhileTheFileFinishesRestartsItsCameras() async throws {
        let url = Self.outputURL("cameras-after-finish")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = VideoEncoder()
        let session = try Self.avatarSession(encoder: encoder)
        let cameraStarts = CameraStartAttempts(session)
        try await session.startRecording(outputURL: url, title: "cameras")
        cameraStarts.enableCamera()
        await encoder.setFinishingHookForTesting { try? await session.startStreamingForTesting { _ in } }

        _ = try? await session.stopRecording()
        await encoder.setFinishingHookForTesting(nil)

        #expect(cameraStarts.attempted == [CameraStartAttempts.cameraID])
        await session.stopStreaming()
    }

    @Test("A stream that starts while a stopped recording releases the sources gets them back")
    func streamStartingWhileTheSourcesAreReleasedGetsThemBack() async throws {
        let url = Self.outputURL("stream-starts-while-releasing")
        defer { try? FileManager.default.removeItem(at: url) }
        let encoder = VideoEncoder()
        let live = try SharedSources(encoder: encoder)
        let session = live.session
        // Stopping this source starts a new stream, once.
        let startsAStream = StreamStartingAudioSource(sourceID: "stream-starter") {
            try? await session.startStreamingForTesting { _ in }
        }
        session.addMuseAudioSource(startsAStream)
        try await live.startRecordingAndStream(to: url)
        // The stream ends while the file finishes, so the stop releases the sources after it.
        await encoder.setFinishingHookForTesting { await session.stopStreaming() }

        _ = try await session.stopRecording()
        await encoder.setFinishingHookForTesting(nil)

        #expect(startsAStream.startedAStream)
        try await Self.waitUntil { live.audio.isActive }
        #expect(live.audio.isActive)
        await session.stopStreaming()
        #expect(!live.audio.isActive)
    }

    @Test("Stopping a paused recording lets the stream's frames through again")
    func stoppingAPausedRecordingResumesTheStream() async throws {
        let url = Self.outputURL("paused-stop")
        defer { try? FileManager.default.removeItem(at: url) }
        let streamFrames = OSAllocatedUnfairLock(initialState: 0)
        let session = try Self.avatarSession()
        try await session.startRecording(outputURL: url, title: "paused stop")
        try await session.startStreamingForTesting { _ in streamFrames.withLock { $0 += 1 } }
        try await Self.waitUntil { streamFrames.withLock { $0 } >= 10 }
        session.pauseRecording()
        try await Task.sleep(for: .milliseconds(300))   // the pause reaches the encoder

        _ = try await session.stopRecording()
        let atStop = streamFrames.withLock { $0 }
        try await Self.waitUntil { streamFrames.withLock { $0 } >= atStop + 10 }
        let afterStop = streamFrames.withLock { $0 } - atStop
        await session.stopStreaming()

        #expect(afterStop >= 10)
    }

    @Test("Recording again while a stream runs reuses the stream's microphone instead of adding a second one")
    func recordingAgainWhileStreamingReusesTheMicrophone() async throws {
        let first = Self.outputURL("record-again-1"), second = Self.outputURL("record-again-2")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let inputs = StandInAudioInputs()
        let session = try Self.avatarSession(audioInputs: inputs.audioInputs)
        session.enableMicrophone = true
        let streamFrames = OSAllocatedUnfairLock(initialState: 0)
        try await session.startRecording(outputURL: first, title: "first")
        try await session.startStreamingForTesting { _ in streamFrames.withLock { $0 += 1 } }
        try await Self.waitUntil { streamFrames.withLock { $0 } >= 5 }
        _ = try? await session.stopRecording()

        try await session.startRecording(outputURL: second, title: "second")

        #expect(inputs.microphones.count == 1)
        #expect(inputs.microphones.filter(\.isActive).count == 1)
        _ = try? await session.stopRecording()
        await session.stopStreaming()
        #expect(inputs.microphones.allSatisfy { !$0.isActive })
    }

    @Test("Stopping the stream while a recording is starting leaves that recording its screen and audio")
    func stoppingTheStreamWhileARecordingStartsKeepsItsSources() async throws {
        let url = Self.outputURL("stream-stops-during-start")
        defer { try? FileManager.default.removeItem(at: url) }
        let live = try SharedSources()
        live.session.enableAvatar = false
        live.session.enableDesktop = true
        try live.session.startScreenPreview()
        let preview = await live.screenInput()
        try await live.session.startStreamingForTesting { _ in }
        try await Self.waitUntil { live.audio.isActive }

        // The recording's start waits for the first frame of its own screen capture.
        let start = Task { try await live.session.startRecording(outputURL: url, title: "starting") }
        let deadline = ContinuousClock.now + .seconds(5)
        while await live.screenInput().map({ $0 === preview }) ?? true, .now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await live.session.stopStreaming()
        #expect(await live.screenIsCapturing())   // the first frame
        try await start.value

        #expect(live.session.isRecording)
        #expect(live.audio.isActive)
        #expect(await live.screenIsCapturing())
        _ = try? await live.session.stopRecording()
        #expect(!live.audio.isActive)
    }

    @Test("A recording start that fails after the stream ended releases the screen and audio")
    func failedStartAfterTheStreamEndedReleasesTheSources() async throws {
        let url = Self.outputURL("failed-start-after-stream")
        defer { try? FileManager.default.removeItem(at: url) }
        // The microphone permission request is held until released, then refused.
        let released = OSAllocatedUnfairLock(initialState: false)
        let asked = OSAllocatedUnfairLock(initialState: false)
        let stand = StandInAudioInputs()
        var inputs = stand.audioInputs
        inputs.microphonePermission = {
            asked.withLock { $0 = true }
            while !released.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
            return false
        }
        let live = try SharedSources(audioInputs: inputs)
        live.session.enableMicrophone = true
        try live.session.startScreenPreview()
        try await live.session.startStreamingForTesting { _ in }
        try await Self.waitUntil { stand.microphones.first?.isActive == true }

        let start = Task { try await live.session.startRecording(outputURL: url, title: "refused") }
        try await Self.waitUntil { asked.withLock { $0 } }
        await live.session.stopStreaming()
        #expect(stand.microphones.first?.isActive == true)   // the starting recording owns it
        released.withLock { $0 = true }
        await #expect(throws: RecorderError.permissionDenied) { try await start.value }

        #expect(stand.microphones.allSatisfy { !$0.isActive })
        #expect(!live.audio.isActive)
        #expect(!(await live.screenIsCapturing()))
    }

    @Test("A stream that starts while a failed recording start releases the sources gets the screen and cameras back, and starts its frames once")
    func streamStartingWhileAFailedStartReleasesTheSourcesGetsThemBack() async throws {
        let url = Self.outputURL("stream-starts-after-failed-start")
        defer { try? FileManager.default.removeItem(at: url) }
        // The microphone permission request is held until released, then refused.
        let released = OSAllocatedUnfairLock(initialState: false)
        let asked = OSAllocatedUnfairLock(initialState: false)
        var inputs = StandInAudioInputs().audioInputs
        inputs.microphonePermission = {
            asked.withLock { $0 = true }
            while !released.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
            return false
        }
        let live = try SharedSources(audioInputs: inputs)
        let session = live.session
        session.enableAvatar = false
        session.enableDesktop = true
        session.enableMicrophone = true
        let cameraStarts = CameraStartAttempts(session)
        // Stopping this source starts a new stream, once: while the failed start releases the sources.
        let startsAStream = StreamStartingAudioSource(sourceID: "stream-starter") {
            try? await session.startStreamingForTesting { _ in }
        }
        session.addMuseAudioSource(startsAStream)
        try session.startScreenPreview()
        try await session.startStreamingForTesting { _ in }
        try await Self.waitUntil { live.audio.isActive }

        let frameStarts = session.streamFrameGenerationStartsForTesting

        let start = Task { try await session.startRecording(outputURL: url, title: "refused") }
        try await Self.waitUntil { asked.withLock { $0 } }
        await session.stopStreaming()   // leaves the sources to the starting recording
        cameraStarts.enableCamera()
        released.withLock { $0 = true }
        await #expect(throws: RecorderError.permissionDenied) { try await start.value }

        #expect(startsAStream.startedAStream)
        // The new stream started its own frames; getting its sources back doesn't start them again.
        #expect(session.streamFrameGenerationStartsForTesting == frameStarts + 1)
        #expect(await live.screenIsCapturing())
        #expect(cameraStarts.attempted == [CameraStartAttempts.cameraID])
        try await Self.waitUntil { live.audio.isActive }
        #expect(live.audio.isActive)
        await session.stopStreaming()
        #expect(!live.audio.isActive)
        #expect(!(await live.screenIsCapturing()))
    }

    @Test("Pausing a recording keeps a live stream going, and the file takes nothing while paused")
    func pausingARecordingKeepsTheStreamGoing() async throws {
        let url = Self.outputURL("paused-stream")
        defer { try? FileManager.default.removeItem(at: url) }
        // Once the encoder is paused, the avatar turns red.
        let paused = OSAllocatedUnfairLock(initialState: false)
        let encoder = VideoEncoder()
        let session = try Self.avatarSession(encoder: encoder)
        let green = try SolidFrame(red: 0, green: 255, blue: 0)
        let red = try SolidFrame(red: 255, green: 0, blue: 0)
        session.avatarTextureProvider = { paused.withLock { $0 } ? red.buffer : green.buffer }
        let streamFrames = OSAllocatedUnfairLock(initialState: 0)
        try await session.startRecording(outputURL: url, title: "paused stream")
        try await session.startStreamingForTesting { _ in streamFrames.withLock { $0 += 1 } }
        try await Self.waitUntil { streamFrames.withLock { $0 } >= 10 }

        session.pauseRecording()
        await encoder.pause()   // the session's pause reaches the encoder in a task; this one is done on return
        paused.withLock { $0 = true }
        let atPause = streamFrames.withLock { $0 }
        try await Task.sleep(for: .seconds(1))
        let whilePaused = streamFrames.withLock { $0 } - atPause
        _ = try await session.stopRecording()
        await session.stopStreaming()

        // About 30 at 30 fps; a held-back stream still shows a few from the encoder's lag.
        #expect(whilePaused >= 15)
        let colors = try await Self.centerColors(in: url)
        #expect(!colors.isEmpty)
        #expect(colors.allSatisfy { $0.g > 150 && $0.r < 100 }, "a frame composed while paused reached the file")
    }

    @Test("A stream's timestamps keep moving forward through a recording's pause, resume and stop")
    func streamTimestampsKeepMovingForwardThroughAPause() async throws {
        let url = Self.outputURL("stream-timeline")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try Self.avatarSession()
        let times = OSAllocatedUnfairLock(initialState: [CMTime]())
        try await session.startRecording(outputURL: url, title: "stream timeline")
        try await session.startStreamingForTesting { frame in
            let pts = frame.pts
            times.withLock { $0.append(pts) }
        }
        try await Self.waitUntil { times.withLock { $0.count } >= 5 }
        session.pauseRecording()
        try await Task.sleep(for: .milliseconds(500))
        session.resumeRecording()
        try await Task.sleep(for: .milliseconds(500))
        _ = try await session.stopRecording()
        let atStop = times.withLock { $0.count }
        try await Self.waitUntil { times.withLock { $0.count } >= atStop + 5 }
        await session.stopStreaming()

        let pts = times.withLock { $0 }
        #expect(pts.count >= 15)
        #expect(zip(pts, pts.dropFirst()).allSatisfy { CMTimeCompare($0, $1) < 0 }, "the stream's timestamps went back")
    }

    @Test("A stream stopped right after it starts leaves no audio source running")
    func streamStoppedRightAfterItStartsLeavesNoAudioRunning() async throws {
        let session = try Self.avatarSession()
        let audio = SlowStartingAudioSource(sourceID: "muse-voice")
        session.addMuseAudioSource(audio)

        try await session.startStreamingForTesting { _ in }
        await session.stopStreaming()

        try await Task.sleep(for: .milliseconds(500))   // longer than a start takes
        #expect(!audio.isActive)
    }

    @Test("A second start while the first is still starting fails with it")
    func secondStartDuringAStartSharesItsFailure() async throws {
        let (session, permission) = try Self.sessionWithHeldPermission()
        let first = Task { try await session.startRecording(outputURL: Self.outputURL("first"), title: "first") }
        try await Self.waitUntil { permission.asked }
        let second = SecondStart(session)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!second.hasEnded, "the second start returned before the first had an outcome")

        permission.answer(false)

        await #expect(throws: RecorderError.permissionDenied) { try await first.value }
        await #expect(throws: RecorderError.permissionDenied) { try await second.task.value }
        #expect(!session.isRecording)
    }

    @Test("A second start while the first is still starting returns once the first has started")
    func secondStartDuringAStartSharesItsSuccess() async throws {
        let (session, permission) = try Self.sessionWithHeldPermission()
        let url = Self.outputURL("shared-start")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = Task { try await session.startRecording(outputURL: url, title: "first") }
        try await Self.waitUntil { permission.asked }
        let second = SecondStart(session)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!second.hasEnded, "the second start returned before the first had an outcome")

        permission.answer(true)

        try await first.value
        try await second.task.value
        #expect(session.isRecording)
        _ = try? await session.stopRecording()
    }

    @Test("Starting a recording while a stream runs keeps the stream's mix: its clock and the voice it has queued")
    func recordingStartedMidStreamKeepsTheMix() async throws {
        let url = Self.outputURL("mid-stream-mix")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try Self.avatarSession()
        let clock = FakeAudioSource(sourceID: "test-clock")
        let voice = FakeAudioSource(sourceID: "muse-voice")
        session.addMuseAudioSource(clock)
        session.addMuseAudioSource(voice)
        try await session.startStreamingForTesting { _ in }
        try await Self.waitUntil { clock.isActive && voice.isActive }
        // The clock delivers first and sets the cadence; the voice is queued, short of its lead.
        clock.onSample?(Self.tone(frames: 1024, amplitude: 0))
        voice.onSample?(Self.tone(frames: 960, amplitude: 8000))
        let mixer = session.audioMixerForTesting
        let queued = mixer.queuedSampleCountForTesting(of: "muse-voice")
        try #require(mixer.clockSourceIDForTesting == "test-clock")
        try #require(queued > 0)

        try await session.startRecording(outputURL: url, title: "mid-stream mix")

        #expect(mixer.clockSourceIDForTesting == "test-clock")
        #expect(mixer.queuedSampleCountForTesting(of: "muse-voice") == queued)
        _ = try? await session.stopRecording()
        await session.stopStreaming()
    }

    @Test("The 30 fps driver composes one frame at a time, so a slow composite skips ticks instead of queueing them")
    func slowCompositeSkipsTicks() async throws {
        let url = Self.outputURL("slow-composite")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try Self.avatarSession()
        let green = try SolidFrame(red: 0, green: 255, blue: 0)
        // Each composite takes 100 ms, three ticks' worth.
        let composites = OSAllocatedUnfairLock(initialState: (running: 0, peak: 0, started: 0))
        session.avatarTextureProvider = {
            composites.withLock { state in
                state.running += 1
                state.peak = max(state.peak, state.running)
                state.started += 1
            }
            Thread.sleep(forTimeInterval: 0.1)
            composites.withLock { $0.running -= 1 }
            return green.buffer
        }
        try await session.startRecording(outputURL: url, title: "slow composite")
        let before = composites.withLock { $0.started }
        try await Task.sleep(for: .seconds(1))
        let during = composites.withLock { $0.started } - before
        _ = try await session.stopRecording()

        // Unbounded, every tick starts a composite: about 30 in the second, three or four at once.
        #expect(composites.withLock { $0.peak } == 1)
        #expect(during <= 12, "\(during) composites started in one second")
    }

    /// An avatar session with the microphone on, whose permission request is held until answered.
    private static func sessionWithHeldPermission() throws -> (RecordingSession, HeldPermission) {
        let permission = HeldPermission()
        var inputs = StandInAudioInputs().audioInputs
        inputs.microphonePermission = { await permission.request() }
        let session = try avatarSession(audioInputs: inputs)
        session.enableMicrophone = true
        return (session, permission)
    }

    private static func outputURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).mov")
    }

    /// Avatar mode, which needs no devices or permissions.
    private static func avatarSession(
        screenCapture: ScreenCaptureManager = ScreenCaptureManager(),
        encoder: VideoEncoder = VideoEncoder(),
        audioInputs: AudioInputs = .system
    ) throws -> RecordingSession {
        let session = try RecordingSession(screenCapture: screenCapture, encoder: encoder, audioInputs: audioInputs)
        session.enableDesktop = false
        session.enableCamera = false
        session.enableMicrophone = false
        session.enableScreenAudio = false
        session.enableAvatar = true
        session.watermarkEnabled = false
        let green = try SolidFrame(red: 0, green: 255, blue: 0)
        session.avatarTextureProvider = { green.buffer }
        return session
    }

    /// Polls `condition` for up to five seconds.
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && .now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The average color at the center of each video frame in the file.
    private static func centerColors(in url: URL) async throws -> [(r: UInt8, g: UInt8, b: UInt8, a: UInt8)] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var colors: [(r: UInt8, g: UInt8, b: UInt8, a: UInt8)] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let pixel = CMSampleBufferGetImageBuffer(sample) else { continue }
            let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
            let center = CGRect(x: width / 2 - 20, y: height / 2 - 20, width: 40, height: 40)
            if let color = getAverageColor(in: pixel, region: center) { colors.append(color) }
        }
        return colors
    }

    /// A 1 kHz tone (silence at amplitude 0) stamped with the host clock, as capture sources are.
    private static func tone(frames: Int, amplitude: Double) -> CMSampleBuffer {
        AudioMixerTests.buffer(frames: frames, pts: CMClockGetTime(CMClockGetHostTimeClock())) { frame in
            Int16(amplitude * sin(2 * .pi * 1000 * Double(frame) / 48000))
        }
    }

    /// The largest absolute sample value in the file's decoded audio.
    private static func peakAudioSample(in url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var peak = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var samples = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(block) / 2)
            _ = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            peak = max(peak, samples.map { abs(Int($0)) }.max() ?? 0)
        }
        return peak
    }
}

/// Takes real inputs and outputs but captures nothing.
private final class NonCapturingSession: AVCaptureSession, @unchecked Sendable {
    override func startRunning() {}
    override func stopRunning() {}
}

/// An avatar-mode session with a screen preview and a stand-in audio source: the sources a
/// recording and a stream share. Captures nothing.
@MainActor
private struct SharedSources {
    let session: RecordingSession
    let audio = FakeAudioSource(sourceID: "muse-voice")
    private let capture: ScreenCaptureManager
    private let captureSession = NonCapturingSession()
    private let screenFrames = OSAllocatedUnfairLock(initialState: 0)

    init(encoder: VideoEncoder = VideoEncoder(), audioInputs: AudioInputs = .system) throws {
        capture = ScreenCaptureManager(captureSession: captureSession)
        let screenFrames = screenFrames
        capture.onFrame = { _ in screenFrames.withLock { $0 += 1 } }
        session = try RecordingSession(screenCapture: capture, encoder: encoder, audioInputs: audioInputs)
        session.enableDesktop = false
        session.enableCamera = false
        session.enableMicrophone = false
        session.enableScreenAudio = false
        session.enableAvatar = true
        session.watermarkEnabled = false
        let green = try SolidFrame(red: 0, green: 255, blue: 0)
        session.avatarTextureProvider = { green.buffer }
        session.addMuseAudioSource(audio)
    }

    /// Starts the screen preview, a recording and a stream, and returns once frames reach both.
    func startRecordingAndStream(to url: URL) async throws {
        try session.startScreenPreview()
        await capture.waitForSessionQueue()
        try await session.startRecording(outputURL: url, title: "shared sources")
        let streamFrames = OSAllocatedUnfairLock(initialState: 0)
        try await session.startStreamingForTesting { _ in streamFrames.withLock { $0 += 1 } }
        // Each frame reaches the file before the stream.
        let deadline = ContinuousClock.now + .seconds(5)
        while streamFrames.withLock({ $0 }) < 5 && .now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(streamFrames.withLock { $0 } >= 5)
    }

    /// The screen input attached once queued session work has run.
    func screenInput() async -> AVCaptureInput? {
        await capture.waitForSessionQueue()
        return captureSession.inputs.first
    }

    /// Whether the screen capture still delivers a frame, once its queued session work has run.
    func screenIsCapturing() async -> Bool {
        await capture.waitForSessionQueue()
        guard let output = captureSession.outputs.first,
              let connection = output.connection(with: .video),
              let pixel = createTestPixelBuffer(width: 16, height: 16, red: 255, green: 0, blue: 0),
              let sample = createTestSampleBuffer(from: pixel) else { return false }
        let before = screenFrames.withLock { $0 }
        capture.captureOutput(output, didOutput: sample, from: connection)
        return screenFrames.withLock { $0 } > before
    }
}

/// One 1080p frame of a solid color, made once: building a frame per call is slow in a debug build.
private struct SolidFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer

    init(red: UInt8, green: UInt8, blue: UInt8) throws {
        buffer = try #require(createTestPixelBuffer(width: 1920, height: 1080, red: red, green: green, blue: blue))
    }
}


/// Audio inputs that capture nothing: microphone permission is granted, and each microphone or
/// screen audio the session makes is a `FakeAudioSource`, kept here.
@MainActor
private final class StandInAudioInputs {
    private(set) var microphones: [FakeAudioSource] = []
    private(set) var screenAudio: [FakeAudioSource] = []

    var audioInputs: AudioInputs {
        AudioInputs(
            microphonePermission: { true },
            makeMicrophone: { [self] in
                let microphone = FakeAudioSource(sourceID: "microphone")
                microphones.append(microphone)
                return microphone
            },
            makeScreenAudio: { [self] in
                let audio = FakeAudioSource(sourceID: "screen")
                screenAudio.append(audio)
                return audio
            }
        )
    }
}

/// An audio source whose start takes 100 ms, as opening a capture device does.
private final class SlowStartingAudioSource: AudioSource, @unchecked Sendable {
    let sourceID: String
    let sourceName = "Slow"
    let format = AudioFormat(sampleRate: 48000, channels: 2, bitDepth: 16, formatID: kAudioFormatLinearPCM)
    var onSample: ((CMSampleBuffer) -> Void)?
    private let active = OSAllocatedUnfairLock(initialState: false)

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    var isActive: Bool { active.withLock { $0 } }

    func start() async throws {
        try await Task.sleep(for: .milliseconds(100))
        active.withLock { $0 = true }
    }

    func stop() async throws {
        active.withLock { $0 = false }
    }
}

/// The session's camera starts, seen with no camera hardware or permission: the camera can't
/// exist, so each start of it is reported to `cameraStartFailureHandler` at once.
@MainActor
private final class CameraStartAttempts {
    static let cameraID = "nonexistent-camera-id"
    private let session: RecordingSession
    private let reported = OSAllocatedUnfairLock(initialState: [String]())

    init(_ session: RecordingSession) {
        self.session = session
        let reported = reported
        session.cameraStartFailureHandler = { failure in reported.withLock { $0.append(failure.sourceID) } }
    }

    /// The cameras whose start was attempted.
    var attempted: [String] { reported.withLock { $0 } }

    /// Turns the camera on. Call it once a recording's start has asked its permissions, so the
    /// start asks for no camera permission.
    func enableCamera() {
        session.cameraSourceIdentifiers = [Self.cameraID]
        session.enableCamera = true
    }
}

/// An audio source whose first stop runs `onFirstStop` before it returns.
private final class StreamStartingAudioSource: AudioSource, @unchecked Sendable {
    let sourceID: String
    let sourceName = "Stream starter"
    let format = AudioFormat(sampleRate: 48000, channels: 2, bitDepth: 16, formatID: kAudioFormatLinearPCM)
    var onSample: ((CMSampleBuffer) -> Void)?
    private let onFirstStop: @Sendable () async -> Void
    private let state = OSAllocatedUnfairLock(initialState: (active: false, stops: 0))

    init(sourceID: String, onFirstStop: @escaping @Sendable () async -> Void) {
        self.sourceID = sourceID
        self.onFirstStop = onFirstStop
    }

    var isActive: Bool { state.withLock { $0.active } }
    var startedAStream: Bool { state.withLock { $0.stops > 0 } }

    func start() async throws {
        state.withLock { $0.active = true }
    }

    func stop() async throws {
        let first = state.withLock { state in
            state.active = false
            state.stops += 1
            return state.stops == 1
        }
        if first { await onFirstStop() }
    }
}

/// A permission request that waits until the test answers it.
private final class HeldPermission: Sendable {
    private let state = OSAllocatedUnfairLock<(asked: Bool, answer: Bool?)>(initialState: (false, nil))

    var asked: Bool { state.withLock { $0.asked } }

    func answer(_ granted: Bool) { state.withLock { $0.answer = granted } }

    func request() async -> Bool {
        state.withLock { $0.asked = true }
        while true {
            if let answer = state.withLock({ $0.answer }) { return answer }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A second `startRecording` call, made with a throwaway URL, that records when it ends.
@MainActor
private final class SecondStart {
    let task: Task<Void, any Error>
    private let ended = OSAllocatedUnfairLock(initialState: false)

    init(_ session: RecordingSession) {
        let ended = ended
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("second-\(UUID().uuidString).mov")
        task = Task {
            defer { ended.withLock { $0 = true } }
            try await session.startRecording(outputURL: url, title: "second")
        }
    }

    var hasEnded: Bool { ended.withLock { $0 } }
}
