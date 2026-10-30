import AVFoundation
import Foundation
import os
import Testing
@testable import ArkavoRecorder

@MainActor
@Suite(.serialized)
struct ComposedPreviewTests {
    @Test("Queued frames from a replaced screen cannot become the composed preview of the new screen")
    func screenPreviewRejectsReplacedSourceAndIncludesOverlays() async throws {
        let captureSession = PreviewCaptureSession()
        let capture = ScreenCaptureManager(captureSession: captureSession)
        let session = try RecordingSession(screenCapture: capture)
        session.enableCamera = false
        session.enableMicrophone = false
        session.enableAvatar = true
        session.watermarkEnabled = false
        session.avatarTextureProvider = { createTestPixelBuffer(width: 1920, height: 1080, red: 0, green: 255, blue: 0) }
        session.museTextureProvider = { createTestPixelBuffer(width: 1920, height: 1080, red: 0, green: 0, blue: 255) }
        let frames = OSAllocatedUnfairLock(initialState: [Frame]())
        session.monitorFrameHandler = { buffer, _ in
            let frame = Frame(buffer)
            frames.withLock { $0.append(frame) }
        }
        session.setComposedPreviewEnabled(true)
        defer {
            session.setComposedPreviewEnabled(false)
            session.stopScreenPreview()
        }
        try session.startScreenPreview()
        await capture.waitForSessionQueue()
        let output = try #require(captureSession.outputs.first)
        let oldConnection = try #require(output.connection(with: .video))
        let oldPixel = try #require(createTestPixelBuffer(width: 1920, height: 1080, red: 255, green: 0, blue: 0))
        let oldFrame = try #require(createTestSampleBuffer(from: oldPixel))
        capture.captureOutput(output, didOutput: oldFrame, from: oldConnection)
        // Replace the source before the queued frame's async composition can run.
        try session.startScreenPreview()
        await capture.waitForSessionQueue()
        let newConnection = try #require(output.connection(with: .video))
        let newPixel = try #require(createTestPixelBuffer(width: 1920, height: 1080, red: 255, green: 255, blue: 0))
        let newFrame = try #require(createTestSampleBuffer(from: newPixel))
        let deadline = ContinuousClock.now + .seconds(10)
        while frames.withLock({ $0.isEmpty }) && .now < deadline {
            capture.captureOutput(output, didOutput: newFrame, from: newConnection)
            try await Task.sleep(for: .milliseconds(50))
        }
        let frame = try #require(frames.withLock { $0.first })
        #expect(frame.center.r > 200 && frame.center.g > 200)
        #expect(frame.avatar.g > 200 && frame.avatar.r < 60)
        #expect(frame.muse.b > 200 && frame.muse.g < 60)
        #expect(frames.withLock { $0.count } == 1)
        #expect(!session.isRecording && session.registeredAudioSourceIDs.isEmpty)
    }

    @Test("An opt-in immediately withdrawn cannot deliver a queued preview frame")
    func disablingBeforeCompositionCancelsQueuedPreview() async throws {
        let session = try Self.avatarSession()
        let frames = OSAllocatedUnfairLock(initialState: 0)
        session.monitorFrameHandler = { _, _ in frames.withLock { $0 += 1 } }
        session.setComposedPreviewEnabled(true)
        session.setComposedPreviewEnabled(false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(frames.withLock { $0 } == 0)
        #expect(!session.isRecording && session.registeredAudioSourceIDs.isEmpty)
    }

    @Test("Changing idle input mode switches composed output from avatar to camera with Muse PiP")
    func idleSourceChangeReconfiguresThePreviewDriver() async throws {
        let session = try Self.avatarSession()
        session.museTextureProvider = { createTestPixelBuffer(width: 1920, height: 1080, red: 0, green: 0, blue: 255) }
        let frames = OSAllocatedUnfairLock(initialState: [Frame]())
        session.monitorFrameHandler = { buffer, _ in
            let frame = Frame(buffer)
            frames.withLock { $0.append(frame) }
        }
        session.setComposedPreviewEnabled(true)
        defer { session.setComposedPreviewEnabled(false) }
        try await Self.waitForFrames(frames, count: 1)
        #expect(frames.withLock { $0.first?.center.g ?? 0 } > 200)

        session.enableAvatar = false
        session.enableCamera = true
        let pixel = try #require(createTestPixelBuffer(width: 1280, height: 720, red: 255, green: 0, blue: 0))
        let sample = try #require(createTestSampleBuffer(from: pixel))
        session.remoteCameraServer(RemoteCameraServer(), didReceiveFrame: sample, sourceID: "test-camera")
        session.inputsDidChange()
        try await Self.waitForFrames(frames, count: 2)
        let camera = try #require(frames.withLock { $0.last })
        #expect(camera.center.r > 200 && camera.center.g < 60)
        #expect(camera.muse.b > 200 && camera.muse.r < 60)
        #expect(!session.isRecording && session.registeredAudioSourceIDs.isEmpty)
    }

    @Test("Idle composed preview includes the avatar, Muse PiP and scene overlay without recording or audio")
    func idlePreviewUsesTheRealCompositor() async throws {
        let session = try Self.avatarSession()
        session.museTextureProvider = { createTestPixelBuffer(width: 1920, height: 1080, red: 0, green: 0, blue: 255) }
        let frames = OSAllocatedUnfairLock(initialState: [Frame]())
        session.monitorFrameHandler = { buffer, _ in
            let frame = Frame(buffer)
            frames.withLock { $0.append(frame) }
        }
        defer { session.setComposedPreviewEnabled(false) }

        try await Task.sleep(for: .milliseconds(100))
        #expect(frames.withLock { $0.isEmpty })
        session.setComposedPreviewEnabled(true)
        try await Self.waitForFrames(frames, count: 1)
        let first = try #require(frames.withLock { $0.first })
        #expect(first.center.g > 200 && first.center.b < 60)
        #expect(first.muse.b > 200 && first.muse.g < 60)
        #expect(!session.isRecording)
        #expect(session.duration == 0)
        #expect(session.registeredAudioSourceIDs.isEmpty)

        session.sceneOverlayText = "Be Right Back"
        session.sceneOverlayGradientColors = (
            CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        try await Self.waitForFrames(frames, count: 2)
        let overlay = try #require(frames.withLock { $0.last })
        #expect(overlay.muse.r > 200 && overlay.muse.b < 60)
        let timestamps = frames.withLock { $0.map(\.time) }
        #expect(timestamps[0].duration(to: timestamps[1]) >= .milliseconds(950))

        session.setComposedPreviewEnabled(false)
        let stoppedCount = frames.withLock { $0.count }
        try await Task.sleep(for: .milliseconds(1200))
        #expect(frames.withLock { $0.count } == stoppedCount)
        #expect(session.registeredAudioSourceIDs.isEmpty)
    }

    @Test("Disabling composed preview during a recording leaves its video driver and file running")
    func disablingPreviewDoesNotStopRecording() async throws {
        let session = try Self.avatarSession()
        let frames = OSAllocatedUnfairLock(initialState: [Frame]())
        session.monitorFrameHandler = { buffer, _ in
            let frame = Frame(buffer)
            frames.withLock { $0.append(frame) }
        }
        session.setComposedPreviewEnabled(true)
        defer { session.setComposedPreviewEnabled(false) }
        try await Self.waitForFrames(frames, count: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-handoff-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await session.startRecording(outputURL: url, title: "preview handoff")
        session.setComposedPreviewEnabled(false)
        let before = frames.withLock { $0.count }
        try await Self.waitForFrames(frames, count: before + 5)
        #expect(session.isRecording)
        #expect(session.registeredAudioSourceIDs.isEmpty)
        _ = try await session.stopRecording()
        let asset = AVURLAsset(url: url)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try await asset.load(.duration).seconds > 0.05)
    }

    @Test("A frame keeps the monitor handler present when its composition began")
    func inFlightFrameKeepsItsOriginalHandler() async throws {
        let session = try Self.avatarSession()
        let original = OSAllocatedUnfairLock(initialState: 0)
        let replacement = OSAllocatedUnfairLock(initialState: 0)
        session.monitorFrameHandler = { _, _ in original.withLock { $0 += 1 } }
        session.avatarTextureProvider = {
            session.monitorFrameHandler = { _, _ in replacement.withLock { $0 += 1 } }
            return createTestPixelBuffer(width: 1920, height: 1080, red: 0, green: 255, blue: 0)
        }
        session.setComposedPreviewEnabled(true)
        defer { session.setComposedPreviewEnabled(false) }
        let deadline = ContinuousClock.now + .seconds(3)
        while original.withLock({ $0 }) + replacement.withLock({ $0 }) == 0 && .now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        session.setComposedPreviewEnabled(false)
        #expect(original.withLock { $0 } == 1)
        #expect(replacement.withLock { $0 } == 0)
    }

    @Test("A source change while a preview frame is composing delivers its replacement without waiting for the 1 s gate")
    func sourceChangeDuringInFlightFrameDeliversPromptly() async throws {
        let session = try Self.avatarSession()
        let compositions = OSAllocatedUnfairLock(initialState: 0)
        session.avatarTextureProvider = {
            // The first frame is still composing when the sources change.
            if compositions.withLock({ count in count += 1; return count }) == 1 {
                Thread.sleep(forTimeInterval: 0.25)
            }
            return createTestPixelBuffer(width: 1920, height: 1080, red: 0, green: 255, blue: 0)
        }
        let frames = OSAllocatedUnfairLock(initialState: [Frame]())
        session.monitorFrameHandler = { buffer, _ in
            let frame = Frame(buffer)
            frames.withLock { $0.append(frame) }
        }
        session.setComposedPreviewEnabled(true)
        defer { session.setComposedPreviewEnabled(false) }
        try await Task.sleep(for: .milliseconds(50))

        let changed = ContinuousClock.now
        session.inputsDidChange()
        try await Self.waitForFrames(frames, count: 1)
        let first = try #require(frames.withLock { $0.first })
        // The frame composed before the change isn't delivered; its replacement follows at once.
        #expect(compositions.withLock { $0 } >= 2)
        #expect(changed.duration(to: first.time) < .milliseconds(900))
    }

    @Test("The session forwards slots to the compositor")
    func sessionSlotsReachTheComposedFrame() async throws {
        let session = try Self.avatarSession()
        session.museTextureProvider = { createTestPixelBuffer(width: 1920, height: 1080, red: 0, green: 0, blue: 255) }
        let gameplayRight = AvatarSlot(slot: CGRect(x: 0.71, y: 0.38, width: 0.28, height: 0.62), anchor: .bottomRight)
        let artLeft = AvatarSlot(slot: CGRect(x: 0.02, y: 0.42, width: 0.20, height: 0.46), anchor: .bottomLeft)
        let body = CGRect(x: 0.3425, y: 0.1, width: 0.315, height: 0.8)
        session.avatarSlot = artLeft
        session.avatarVisibleRect = body
        session.museVisibleRect = body
        #expect(session.avatarSlot == artLeft)
        #expect(session.avatarVisibleRect == body)
        #expect(session.museVisibleRect == body)
        session.museSlot = gameplayRight
        session.museVisibleRect = AvatarSlotLayout.fullTexture
        #expect(session.museSlot == gameplayRight)
        #expect(session.museVisibleRect == AvatarSlotLayout.fullTexture)

        let frames = OSAllocatedUnfairLock(initialState: [Frame]())
        session.monitorFrameHandler = { buffer, _ in
            let frame = Frame(buffer)
            frames.withLock { $0.append(frame) }
        }
        session.setComposedPreviewEnabled(true)
        defer { session.setComposedPreviewEnabled(false) }
        try await Self.waitForFrames(frames, count: 1)
        // Muse moved to the avatar's default slot; the avatar is the base, which fills the output.
        let first = try #require(frames.withLock { $0.first })
        #expect(first.avatar.b > 200 && first.avatar.g < 60)
        #expect(first.muse.g > 200 && first.muse.b < 60)
    }

    @Test("The session forwards a one-step placement to the compositor")
    func sessionForwardsTheOneStepPlacement() throws {
        let session = try Self.avatarSession()
        let artRight = AvatarSlot(slot: CGRect(x: 0.78, y: 0.42, width: 0.20, height: 0.46), anchor: .bottomRight)
        let conversation = AvatarSlot(slot: CGRect(x: 0.22, y: 0.08, width: 0.56, height: 0.92), anchor: .bottomCenter)
        let body = CGRect(x: 0.3425, y: 0.1, width: 0.315, height: 0.8)
        let museRect = CGRect(x: 0.2, y: 0.05, width: 0.6, height: 0.9)
        session.setLayerPlacement(
            avatarSlot: artRight, avatarVisibleRect: body, museSlot: conversation, museVisibleRect: museRect)
        #expect(session.avatarSlot == artRight)
        #expect(session.avatarVisibleRect == body)
        #expect(session.museSlot == conversation)
        #expect(session.museVisibleRect == museRect)
    }

    private static func avatarSession() throws -> RecordingSession {
        let session = try RecordingSession()
        session.enableDesktop = false
        session.enableCamera = false
        session.enableMicrophone = false
        session.enableAvatar = true
        session.watermarkEnabled = false
        session.avatarTextureProvider = { createTestPixelBuffer(width: 1920, height: 1080, red: 0, green: 255, blue: 0) }
        return session
    }

    private struct Frame: Sendable {
        let time = ContinuousClock.now
        let center: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)
        /// The centre of the default avatar slot, Gameplay right: (1363.2, 777.6, 537.6, 302.4).
        let avatar: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)
        /// The centre of the default Muse slot, Gameplay left: (19.2, 777.6, 537.6, 302.4).
        let muse: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)
        init(_ buffer: CVPixelBuffer) {
            center = getAverageColor(in: buffer, region: CGRect(x: 940, y: 520, width: 40, height: 40))!
            avatar = getAverageColor(in: buffer, region: CGRect(x: 1612, y: 909, width: 40, height: 40))!
            muse = getAverageColor(in: buffer, region: CGRect(x: 268, y: 909, width: 40, height: 40))!
        }
    }

    private static func waitForFrames(_ frames: OSAllocatedUnfairLock<[Frame]>, count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while frames.withLock({ $0.count }) < count && .now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(frames.withLock { $0.count } >= count)
    }
}

private final class PreviewCaptureSession: AVCaptureSession, @unchecked Sendable {
    override func startRunning() {}
    override func stopRunning() {}
}
