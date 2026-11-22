import AVFoundation
import ArkavoStreaming
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import os
import Testing
@testable import ArkavoRecorder

/// Focused regression tests for audit fixes across `CompositorManager`, `PersonSegmentationProcessor`,
/// `VideoEncoder`, and `VideoStreamDecoder`.
@Suite("Recorder Video Audit Fixes Tests")
struct RecorderVideoAuditFixesTests {

    // Verified H.264 High Profile SPS & PPS parameter sets (matching LocalHTTPServerPlaybackTests)
    private static let sampleSPS = Data([
        0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9, 0x40, 0x50,
        0x05, 0xBB, 0x01, 0x10, 0x00, 0x00, 0x03, 0x00,
        0x10, 0x00, 0x00, 0x03, 0x03, 0xC0, 0xF1, 0x83,
        0x19, 0x60,
    ])
    private static let samplePPS = Data([0x68, 0xEE, 0x3C, 0x80])

    // MARK: - #38: Multi-camera explicit corner positions

    @Test("Multi-camera layers with explicit corner positions render in their assigned corners without overlapping")
    func multiCameraExplicitCornersDoNotOverlap() throws {
        let compositor = try CompositorManager()
        compositor.outputSize = CGSize(width: 1920, height: 1080)
        compositor.watermarkEnabled = false
        compositor.pipScale = 0.2
        compositor.pipPosition = .bottomRight

        // Black screen base
        let screenBuffer = try #require(Self.makePixelBuffer(width: 1920, height: 1080, r: 0, g: 0, b: 0))
        let screenSample = try #require(Self.makeVideoSampleBuffer(from: screenBuffer))

        // Four distinctly colored cameras pinned to all four explicit corners
        let pixTL = try #require(Self.makePixelBuffer(width: 640, height: 360, r: 255, g: 0, b: 0))
        let pixTR = try #require(Self.makePixelBuffer(width: 640, height: 360, r: 0, g: 255, b: 0))
        let pixBL = try #require(Self.makePixelBuffer(width: 640, height: 360, r: 0, g: 0, b: 255))
        let pixBR = try #require(Self.makePixelBuffer(width: 640, height: 360, r: 255, g: 255, b: 0))
        let camTL = try #require(Self.makeVideoSampleBuffer(from: pixTL))
        let camTR = try #require(Self.makeVideoSampleBuffer(from: pixTR))
        let camBL = try #require(Self.makeVideoSampleBuffer(from: pixBL))
        let camBR = try #require(Self.makeVideoSampleBuffer(from: pixBR))

        let layers: [CompositorManager.CameraLayer] = [
            CompositorManager.CameraLayer(id: "cam-0", buffer: camTL, position: .topLeft),
            CompositorManager.CameraLayer(id: "cam-1", buffer: camTR, position: .topRight),
            CompositorManager.CameraLayer(id: "cam-2", buffer: camBL, position: .bottomLeft),
            CompositorManager.CameraLayer(id: "cam-3", buffer: camBR, position: .bottomRight),
        ]

        let output = try #require(compositor.composite(screen: screenSample, cameraLayers: layers))

        // Sample interior centers of each corner PiP (top-left origin in CVPixelBuffer memory)
        // With 4 cameras and pipScale 0.2, each PiP is 1920*0.14=268.8 x 1080*0.14=151.2 with 20px margin
        let topLeft = try #require(Self.samplePixel(in: output, x: 150, y: 95))
        let topRight = try #require(Self.samplePixel(in: output, x: 1770, y: 95))
        let bottomLeft = try #require(Self.samplePixel(in: output, x: 150, y: 985))
        let bottomRight = try #require(Self.samplePixel(in: output, x: 1770, y: 985))

        // Top-left = Red (cam-0)
        #expect(topLeft.r > 200 && topLeft.g < 40 && topLeft.b < 40, "topLeft got \(topLeft)")
        // Top-right = Green (cam-1) — previously overlapped cam-0 at topLeft!
        #expect(topRight.g > 200 && topRight.r < 40 && topRight.b < 40, "topRight got \(topRight)")
        // Bottom-left = Blue (cam-2)
        #expect(bottomLeft.b > 200 && bottomLeft.r < 40 && bottomLeft.g < 40, "bottomLeft got \(bottomLeft)")
        // Bottom-right = Yellow (cam-3)
        #expect(bottomRight.r > 200 && bottomRight.g > 200 && bottomRight.b < 40, "bottomRight got \(bottomRight)")
    }

    // MARK: - #37: Invalid audio duration does not poison appendedMediaEnd or break pause/resume

    @Test("Audio sample with invalid duration does not poison appendedMediaEnd across pause and resume")
    func invalidAudioDurationDoesNotPoisonPauseResume() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-invalid-dur-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = VideoEncoder()
        try await encoder.startRecording(to: url, title: "invalid-duration", audioSourceIDs: ["microphone"], videoEnabled: false)

        // Feed 0.4s of normal 20ms audio (20 buffers)
        for i in 0..<20 {
            let pts = CMTime(value: CMTimeValue(i * 960), timescale: 48000)
            let buf = try #require(Self.makePCMSampleBuffer(frames: 960, pts: pts, duration: CMTime(value: 1, timescale: 48000)))
            await encoder.encodeAudioSample(buf, sourceID: "microphone")
            try await Task.sleep(for: .milliseconds(20))
        }

        // Feed a buffer whose timing entry has .invalid duration (CMSampleBufferGetDuration == .invalid)
        let invalidDurPTS = CMTime(value: CMTimeValue(20 * 960), timescale: 48000)
        let invalidDurBuf = try #require(Self.makePCMSampleBuffer(frames: 960, pts: invalidDurPTS, duration: .invalid))
        await encoder.encodeAudioSample(invalidDurBuf, sourceID: "microphone")
        try await Task.sleep(for: .milliseconds(20))

        // Pause for 1.0s on timeline, then resume and feed another 0.4s
        await encoder.pause()
        await encoder.resume()

        for i in 0..<20 {
            // Starts 1.0s after the pre-pause end (at t = 1.42s)
            let pts = CMTime(value: CMTimeValue(48000 + (21 + i) * 960), timescale: 48000)
            let buf = try #require(Self.makePCMSampleBuffer(frames: 960, pts: pts, duration: CMTime(value: 1, timescale: 48000)))
            await encoder.encodeAudioSample(buf, sourceID: "microphone")
            try await Task.sleep(for: .milliseconds(20))
        }

        let liveDuration = await encoder.duration
        #expect(liveDuration.isFinite && liveDuration > 0.5 && liveDuration < 1.2,
                "Expected finite post-resume duration ~0.82s, got \(liveDuration)")

        _ = try await encoder.finishRecording()
        let asset = AVURLAsset(url: url)
        let fileDuration = try await asset.load(.duration).seconds
        #expect(abs(fileDuration - 0.82) < 0.15, "Expected ~0.82s file duration without 1s pause gap, got \(fileDuration)")
    }

    // MARK: - L1: Audio-only duration & invalid audio PTS validation

    @Test("Audio-only recording reports real duration and ignores invalid initial audio PTS")
    func audioOnlyReportsRealDurationAndRejectsInvalidPTS() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-audio-only-dur-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let encoder = VideoEncoder()
        try await encoder.startRecording(to: url, title: "audio-only-duration", audioSourceIDs: ["microphone"], videoEnabled: false)

        // Feed an audio buffer with .invalid PTS first — must not anchor startTime
        let badBuf = try #require(Self.makePCMSampleBuffer(frames: 960, pts: .invalid, duration: CMTime(value: 1, timescale: 48000)))
        await encoder.encodeAudioSample(badBuf, sourceID: "microphone")
        #expect(await encoder.duration == 0)

        // Feed 0.5s (25 x 20ms) of valid audio
        for i in 0..<25 {
            let pts = CMTime(value: CMTimeValue(48000 + i * 960), timescale: 48000)
            let buf = try #require(Self.makePCMSampleBuffer(frames: 960, pts: pts, duration: CMTime(value: 1, timescale: 48000)))
            await encoder.encodeAudioSample(buf, sourceID: "microphone")
            try await Task.sleep(for: .milliseconds(20))
        }

        let reportedDuration = await encoder.duration
        #expect(reportedDuration > 0.35 && reportedDuration <= 0.6,
                "Audio-only VideoEncoder.duration should reflect appended audio (~0.5s), got \(reportedDuration)")

        _ = try await encoder.finishRecording()
    }

    // MARK: - C13: VideoStreamDecoder Annex-B & AVCC SPS/PPS extraction and format description setup

    @Test("VideoStreamDecoder extracts SPS and PPS from Annex-B (3-byte & 4-byte) and AVCC streams")
    func videoStreamDecoderExtractsParameterSetsFromAnnexBAndAVCC() throws {
        let fakeIDR = Data([0x65, 0x88, 0x84, 0x00, 0x11, 0x22, 0x33, 0x44])

        // 1. Annex-B with 4-byte start codes
        var annexB4 = Data()
        annexB4.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        annexB4.append(Self.sampleSPS)
        annexB4.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        annexB4.append(Self.samplePPS)
        annexB4.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        annexB4.append(fakeIDR)

        let extracted4 = VideoStreamDecoder.extractParameterSets(from: annexB4)
        #expect(extracted4.sps == Self.sampleSPS)
        #expect(extracted4.pps == Self.samplePPS)
        #expect(VideoStreamDecoder.extractNALUnits(from: annexB4).count == 3)

        // 2. Annex-B with 3-byte start codes (including Data slice with non-zero startIndex)
        var annexB3Prefixed = Data([0xAA, 0xBB])
        annexB3Prefixed.append(contentsOf: [0x00, 0x00, 0x01])
        annexB3Prefixed.append(Self.sampleSPS)
        annexB3Prefixed.append(contentsOf: [0x00, 0x00, 0x01])
        annexB3Prefixed.append(Self.samplePPS)
        let annexB3Slice = annexB3Prefixed.dropFirst(2)
        #expect(annexB3Slice.startIndex == 2)

        let extracted3 = VideoStreamDecoder.extractParameterSets(from: annexB3Slice)
        #expect(extracted3.sps == Self.sampleSPS)
        #expect(extracted3.pps == Self.samplePPS)

        // 3. AVCC 4-byte length-prefixed (including a 288-byte NAL whose length starts with 00 00 01 20)
        var bigIDR = Data([0x65])
        bigIDR.append(Data(repeating: 0xAB, count: 287)) // 288 bytes total -> 0x00000120
        let avcc = VideoStreamDecoder.convertToAVCC(nalUnits: [Self.sampleSPS, Self.samplePPS, bigIDR])

        let extractedAVCC = VideoStreamDecoder.extractParameterSets(from: avcc)
        #expect(extractedAVCC.sps == Self.sampleSPS)
        #expect(extractedAVCC.pps == Self.samplePPS)
        let avccNALs = VideoStreamDecoder.extractNALUnits(from: avcc)
        #expect(avccNALs.count == 3)
        #expect(avccNALs[2] == bigIDR)

        // 4. Decoding an Annex-B SPS+PPS config packet initializes formatDescription without throwing
        let decoder = VideoStreamDecoder { _, _ in }
        decoder.start()
        var configPacket = Data()
        configPacket.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        configPacket.append(Self.sampleSPS)
        configPacket.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        configPacket.append(Self.samplePPS)

        try decoder.decode(configPacket, isKeyFrame: true, timestamp: .zero)
        #expect(decoder.currentFormatDescription != nil)

        // 5. Public setFormatDescription helper replaces formatDescription cleanly
        let manualFormat = try VideoStreamDecoder.createFormatDescription(sps: Self.sampleSPS, pps: Self.samplePPS)
        decoder.invalidate()
        #expect(decoder.currentFormatDescription == nil)
        decoder.setFormatDescription(manualFormat)
        #expect(decoder.currentFormatDescription != nil)
        decoder.invalidate()
    }

    // MARK: - M3 & #42: CompositorManager zero-dimension guards & gradient cache key

    @Test("CompositorManager safely rejects zero, negative, and NaN dimensions")
    func compositorZeroAndNonFiniteDimensionGuards() throws {
        let compositor = try CompositorManager()
        compositor.watermarkEnabled = false

        let pixel = try #require(Self.makePixelBuffer(width: 64, height: 64, r: 255, g: 0, b: 0))
        let sample = try #require(Self.makeVideoSampleBuffer(from: pixel))
        let layer = CompositorManager.CameraLayer(id: "cam", buffer: sample, position: .bottomRight)

        // Invalid canvasSize returns nil cleanly
        #expect(compositor.composite(cameraLayers: [layer], canvasSize: .zero) == nil)
        #expect(compositor.composite(cameraLayers: [layer], canvasSize: CGSize(width: -100, height: 100)) == nil)
        #expect(compositor.composite(cameraLayers: [layer], canvasSize: CGSize(width: CGFloat.nan, height: 100)) == nil)

        // Invalid outputSize returns nil cleanly
        compositor.outputSize = .zero
        #expect(compositor.composite(screen: sample, cameraLayers: []) == nil)
        compositor.outputSize = CGSize(width: CGFloat.infinity, height: 1080)
        #expect(compositor.composite(screen: sample, cameraLayers: []) == nil)

        // Valid outputSize with zero/NaN pipScale still renders base without crashing
        compositor.outputSize = CGSize(width: 320, height: 180)
        compositor.pipScale = 0
        #expect(compositor.composite(screen: sample, cameraLayers: [layer]) != nil)
        compositor.pipScale = .nan
        #expect(compositor.composite(screen: sample, cameraLayers: [layer]) != nil)

        // PersonSegmentationProcessor.applyMask guards zero-extent masks
        let processor = PersonSegmentationProcessor()
        let validImage = CIImage(color: .red).cropped(to: CGRect(x: 10, y: 20, width: 64, height: 64))
        let emptyMask = CIImage.empty()
        let unchanged = processor.applyMask(to: validImage, mask: emptyMask)
        #expect(unchanged.extent == validImage.extent)
    }

    #if os(macOS)
    @Test("CompositorManager scene overlay cache key includes gradient colors and re-renders when gradient changes")
    func sceneOverlayCacheKeyIncludesGradientColors() throws {
        let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        let blue = CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        let size = CGSize(width: 320, height: 180)

        let redKey = CompositorManager.sceneOverlayCacheKey(
            text: "Starting Soon",
            icon: "sparkles",
            gradientColors: (red, red),
            size: size
        )
        let blueKey = CompositorManager.sceneOverlayCacheKey(
            text: "Starting Soon",
            icon: "sparkles",
            gradientColors: (blue, blue),
            size: size
        )
        #expect(redKey != blueKey)

        // End-to-end render with same text + icon and changing gradient colors (off main thread!)
        let compositor = try CompositorManager()
        compositor.outputSize = size
        compositor.watermarkEnabled = false
        compositor.sceneOverlayText = "Be Right Back"
        compositor.sceneOverlayIcon = "cup.and.saucer.fill"

        let screen = try #require(Self.makePixelBuffer(width: 320, height: 180, r: 0, g: 255, b: 0))
        let screenSample = try #require(Self.makeVideoSampleBuffer(from: screen))

        compositor.sceneOverlayGradientColors = (red, red)
        let redFrame = try #require(compositor.composite(screen: screenSample, cameraLayers: []))
        let redPixel = try #require(Self.samplePixel(in: redFrame, x: 10, y: 10))
        #expect(redPixel.r > 200 && redPixel.b < 40, "Expected red overlay corner, got \(redPixel)")

        compositor.sceneOverlayGradientColors = (blue, blue)
        let blueFrame = try #require(compositor.composite(screen: screenSample, cameraLayers: []))
        let bluePixel = try #require(Self.samplePixel(in: blueFrame, x: 10, y: 10))
        #expect(bluePixel.b > 200 && bluePixel.r < 40, "Expected blue overlay corner after gradient change, got \(bluePixel)")
    }
    #endif

    // MARK: - PR #88 Review Fixes: Concurrent stream startup & CameraManager input-switch gating

    @Test("VideoEncoder concurrent startStreaming propagates failure to joiners instead of silently succeeding")
    func videoEncoderConcurrentStartStreamingPropagatesFailureToJoiners() async throws {
        let encoder = VideoEncoder(quality: .performance)
        let hookState = OSAllocatedUnfairLock(initialState: (entered: false, release: false))
        await encoder.setStreamStartHookForTesting {
            hookState.withLock { $0.entered = true }
            while !hookState.withLock({ $0.release }) {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        let first = Task {
            try await encoder.startStreaming(to: [])
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while !hookState.withLock({ $0.entered }) && .now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(hookState.withLock { $0.entered })

        let secondFinished = OSAllocatedUnfairLock(initialState: false)
        let second = Task {
            defer { secondFinished.withLock { $0 = true } }
            try await encoder.startStreaming(to: [])
        }

        try await Task.sleep(for: .milliseconds(50))
        #expect(!secondFinished.withLock { $0 }, "Concurrent joiner must wait for in-flight start rather than returning early")

        hookState.withLock { $0.release = true }

        await #expect(throws: VideoEncoder.StreamingError.self) {
            try await first.value
        }
        await #expect(throws: VideoEncoder.StreamingError.self) {
            try await second.value
        }
        let streamingActive = await encoder.isStreamingActive
        #expect(!streamingActive)
    }

    @Test("VideoEncoder rejects mismatched concurrent NTDF or RTMP starts instead of silently succeeding")
    func videoEncoderRejectsMismatchedConcurrentStreamStarts() async throws {
        let encoder = VideoEncoder(quality: .performance)
        let hookState = OSAllocatedUnfairLock(initialState: (entered: false, release: false))
        await encoder.setStreamStartHookForTesting {
            hookState.withLock { $0.entered = true }
            while !hookState.withLock({ $0.release }) {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        let destA = (
            id: "twitch",
            destination: RTMPPublisher.Destination(url: "rtmp://127.0.0.1:1/app", platform: "twitch"),
            streamKey: "key-a"
        )
        let destB = (
            id: "youtube",
            destination: RTMPPublisher.Destination(url: "rtmp://127.0.0.1:1/live2", platform: "youtube"),
            streamKey: "key-b"
        )

        let first = Task {
            try await encoder.startStreaming(to: [destA])
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while !hookState.withLock({ $0.entered }) && .now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(hookState.withLock { $0.entered })

        // Concurrent NTDF start during in-flight plaintext RTMP start must fail immediately with alreadyStreaming
        let kasURL = try #require(URL(string: "https://platform.arkavo.net"))
        await #expect(throws: VideoEncoder.StreamingError.alreadyStreaming) {
            try await encoder.startNTDFStreaming(
                kasURL: kasURL,
                rtmpURL: "rtmp://127.0.0.1:1/app",
                streamKey: "key-a"
            )
        }

        // Concurrent RTMP start with different destinations must also fail immediately with alreadyStreaming
        await #expect(throws: VideoEncoder.StreamingError.alreadyStreaming) {
            try await encoder.startStreaming(to: [destB])
        }

        hookState.withLock { $0.release = true }
        await #expect(throws: VideoEncoder.StreamingError.self) {
            try await first.value
        }
        #expect(await !encoder.isStreamingActive)
    }

    @Test("VideoEncoder stopStreaming during in-flight start aborts cleanly without leaving streaming active")
    func videoEncoderStopStreamingDuringInFlightStartAbortsCleanly() async throws {
        let encoder = VideoEncoder(quality: .performance)
        let hookState = OSAllocatedUnfairLock(initialState: (entered: false, release: false))
        await encoder.setStreamStartHookForTesting {
            hookState.withLock { $0.entered = true }
            while !hookState.withLock({ $0.release }) {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        let first = Task {
            try await encoder.startStreaming(to: [])
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while !hookState.withLock({ $0.entered }) && .now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(hookState.withLock { $0.entered })

        let joiner = Task {
            try await encoder.startStreaming(to: [])
        }
        try await Task.sleep(for: .milliseconds(25))

        await encoder.stopStreaming()
        hookState.withLock { $0.release = true }

        await #expect(throws: CancellationError.self) {
            try await first.value
        }
        await #expect(throws: CancellationError.self) {
            try await joiner.value
        }
        #expect(await !encoder.isStreamingActive)
    }

    @Test("CameraManager ignores stale frames received before input switch completes")
    @MainActor
    func cameraManagerIgnoresFramesUntilInputSwitchCompletes() async throws {
        let manager = CameraManager()
        let deliveredCount = OSAllocatedUnfairLock(initialState: 0)
        manager.onFrame = { _ in
            deliveredCount.withLock { $0 += 1 }
        }

        let pixel = try #require(Self.makePixelBuffer(width: 64, height: 64, r: 0, g: 255, b: 0))
        let sample = try #require(Self.makeVideoSampleBuffer(from: pixel))

        let oldInputToken = NSObject()
        let newInputToken = NSObject()
        let oldInputID = ObjectIdentifier(oldInputToken)
        let newInputID = ObjectIdentifier(newInputToken)

        // Establish initial active capture A
        let captureA = UUID()
        manager.beginInputSwitch(captureID: captureA)
        manager.commitInputSwitch(captureID: captureA, inputID: oldInputID)
        manager.handleOutputFrame(sample, fromInput: oldInputID)
        #expect(deliveredCount.withLock { $0 } == 1)

        // Begin switching to capture B and await its first frame
        let captureB = UUID()
        manager.beginInputSwitch(captureID: captureB)

        let firstFrameReceived = OSAllocatedUnfairLock(initialState: false)
        let waitTask = Task { @MainActor in
            try await manager.waitForFirstFrameForTesting(captureID: captureB)
            firstFrameReceived.withLock { $0 = true }
        }
        await Task.yield()

        // Stale frames received before commitConfiguration must be ignored
        manager.handleOutputFrame(sample, fromInput: oldInputID)
        manager.handleOutputFrame(sample, fromInput: newInputID)
        try await Task.sleep(for: .milliseconds(30))
        #expect(deliveredCount.withLock { $0 } == 1)
        #expect(!firstFrameReceived.withLock { $0 })

        // Commit input switch to capture B
        manager.commitInputSwitch(captureID: captureB, inputID: newInputID)

        // Late frame from the old input or a torn-down connection (nil inputID) must be ignored
        manager.handleOutputFrame(sample, fromInput: oldInputID)
        manager.handleOutputFrame(sample, fromInput: nil)
        try await Task.sleep(for: .milliseconds(30))
        #expect(deliveredCount.withLock { $0 } == 1)
        #expect(!firstFrameReceived.withLock { $0 })

        // Frame from the new committed input is delivered and satisfies first-frame wait
        manager.handleOutputFrame(sample, fromInput: newInputID)
        try await waitTask.value
        #expect(deliveredCount.withLock { $0 } == 2)
        #expect(firstFrameReceived.withLock { $0 })
        _ = (oldInputToken, newInputToken)
    }

    // MARK: - Helpers

    private static func makePixelBuffer(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let pixelBuffer = buffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                ptr[offset + 0] = b
                ptr[offset + 1] = g
                ptr[offset + 2] = r
                ptr[offset + 3] = 255
            }
        }
        return pixelBuffer
    }

    private static func makeVideoSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDesc: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDesc
        ) == noErr, let formatDesc else {
            return nil
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDesc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else {
            return nil
        }
        return sampleBuffer
    }

    private static func samplePixel(in pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let offset = y * bytesPerRow + x * 4
        return (r: ptr[offset + 2], g: ptr[offset + 1], b: ptr[offset + 0])
    }

    private static func makePCMSampleBuffer(frames: Int, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        ) == noErr, let formatDesc else {
            return nil
        }

        let byteCount = frames * 4
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else {
            return nil
        }

        let pcm = Data(repeating: 0, count: byteCount)
        let copyStatus = pcm.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = 4
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }
}
