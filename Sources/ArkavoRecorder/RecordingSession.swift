import CoreGraphics
import Foundation
import os

#if os(macOS)
@preconcurrency import AVFoundation
import ArkavoMedia
import ArkavoStreaming
import CoreImage
import VideoToolbox

/// Recording input mode determining which sources are active
public enum RecordingInputMode: String, Sendable, CaseIterable, Identifiable {
    case desktopWithCameraAndMic = "Desktop + Camera + Mic"
    case desktopWithMic = "Desktop + Mic"
    case desktopWithCamera = "Desktop + Camera"
    case desktopOnly = "Desktop Only"
    case cameraWithMic = "Camera + Mic"
    case cameraOnly = "Camera Only"
    case avatarWithMic = "Avatar + Mic"
    case avatarOnly = "Avatar Only"
    case audioOnly = "Audio Only"

    public var id: String { rawValue }

    public var needsDesktop: Bool {
        switch self {
        case .desktopWithCameraAndMic, .desktopWithMic, .desktopWithCamera, .desktopOnly:
            return true
        default:
            return false
        }
    }

    public var needsCamera: Bool {
        switch self {
        case .desktopWithCameraAndMic, .desktopWithCamera, .cameraWithMic, .cameraOnly:
            return true
        default:
            return false
        }
    }

    public var needsAvatar: Bool {
        switch self {
        case .avatarWithMic, .avatarOnly:
            return true
        default:
            return false
        }
    }

    public var needsMicrophone: Bool {
        switch self {
        case .desktopWithCameraAndMic, .desktopWithMic, .cameraWithMic, .avatarWithMic, .audioOnly:
            return true
        default:
            return false
        }
    }

    public var needsVideo: Bool {
        self != .audioOnly
    }
}

/// Runs async work one item after another, in the order it was enqueued, and can wait until
/// everything enqueued so far has run.
private final class OrderedDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Task<Void, Never>?

    func enqueue(_ work: sending @escaping () async -> Void) {
        lock.lock()
        let previous = last
        last = Task {
            await previous?.value
            await work()
        }
        lock.unlock()
    }

    /// Returns once every item enqueued before the call has run.
    func waitUntilDelivered() async {
        let last = lock.withLock { self.last }
        await last?.value
    }
}

/// The system audio inputs a session creates: the microphone, with its permission, and the
/// screen's audio. Tests substitute stand-ins.
struct AudioInputs {
    var microphonePermission: () async -> Bool
    var makeMicrophone: @MainActor () -> any AudioSource
    var makeScreenAudio: @MainActor () -> any AudioSource

    @MainActor static var system: AudioInputs {
        AudioInputs(
            microphonePermission: { await MicrophoneAudioSource.requestPermission() },
            makeMicrophone: { MicrophoneAudioSource(sourceID: "microphone") },
            makeScreenAudio: { ScreenAudioSource(sourceID: "screen") }
        )
    }
}

/// Coordinates screen, camera, and audio capture with composition and encoding
@MainActor
public final class RecordingSession: Sendable {
    // MARK: - Properties

    /// Registry for coordinating capture source readiness
    private let sourceRegistry = CaptureSourceRegistry()

    private let screenCapture: ScreenCaptureManager
    private var cameraCaptures: [String: CameraManager]
    private var latestCameraMetadata: [String: CameraMetadata] = [:]
    private var remoteCameraIdentifiers: Set<String> = []
    public private(set) var remoteCameraServer: RemoteCameraServer?
    nonisolated(unsafe) private let audioRouter: AudioRouter
    nonisolated(unsafe) private let audioMixer: AudioMixer
    /// Hands the mix to the encoder in mix order, so stopping can wait until all of it,
    /// the drained tail included, has reached the encoder.
    nonisolated private let mixedAudioDelivery = OrderedDelivery()
    nonisolated(unsafe) private let compositor: CompositorManager
    nonisolated(unsafe) private let encoder: VideoEncoder
    private let audioInputs: AudioInputs

    // Recording state tracked locally for synchronous access
    // This is updated when recording starts/stops
    nonisolated(unsafe) private var _isRecording: Bool = false
    /// From the start of `startRecording` until it returns or throws. A recording that is still
    /// starting owns the sources it is starting, as a running one does.
    private var recordingStarting = false
    /// A stream ended while a recording was starting and left the sources to it.
    private var streamLeftSourcesToStartingRecording = false
    /// Other `startRecording` calls made while one is starting: they get its outcome. Nil when
    /// no start is under way.
    private var startJoiners: [CheckedContinuation<Void, any Error>]?
    private let _streamingActive = OSAllocatedUnfairLock(initialState: false)
    private var recordingStartTime: ContinuousClock.Instant?
    private var pauseStartTime: ContinuousClock.Instant?
    private var pausedDuration: Duration = .zero
    private struct ComposedPreviewState {
        var enabled = false
        var generation: UInt64 = 0
        var lastFrameTime: ContinuousClock.Instant?
        var inFlight = false
    }
    private let composedPreview = OSAllocatedUnfairLock(initialState: ComposedPreviewState())
    private var composedPreviewTimer: Timer?
    private typealias MonitorHandler = @Sendable (CVPixelBuffer, CMTime) -> Void
    private struct FrameDelivery: Sendable {
        let handler: MonitorHandler?
        let previewGeneration: UInt64?
    }
    private let previewCIContext = CIContext()

    // Cache for floating head segmentation to avoid running it twice per frame
    nonisolated(unsafe) private var cachedSegmentedImages: [String: CIImage] = [:]

    nonisolated public var isRecording: Bool {
        _isRecording
    }

    public var duration: TimeInterval {
        guard _isRecording, let startTime = recordingStartTime else { return 0 }
        let elapsed = startTime.duration(to: pauseStartTime ?? .now) - pausedDuration
        let components = elapsed.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    nonisolated(unsafe) public var audioLevel: Float = 0.0

    // Configuration

    /// The corner a camera PiP goes to; avatar and Muse use `avatarSlot` / `museSlot`.
    public var pipPosition: PiPPosition {
        get { compositor.pipPosition }
        set { compositor.pipPosition = newValue }
    }

    /// The avatar overlay's slot over a screen (`CompositorManager.avatarSlot`).
    public var avatarSlot: AvatarSlot {
        get { compositor.avatarSlot }
        set { compositor.avatarSlot = newValue }
    }

    /// The part of the avatar texture fitted into `avatarSlot` (`CompositorManager.avatarVisibleRect`).
    public var avatarVisibleRect: CGRect {
        get { compositor.avatarVisibleRect }
        set { compositor.avatarVisibleRect = newValue }
    }

    /// The Muse layer's slot (`CompositorManager.museSlot`).
    public var museSlot: AvatarSlot {
        get { compositor.museSlot }
        set { compositor.museSlot = newValue }
    }

    /// The part of the Muse texture fitted into `museSlot` (`CompositorManager.museVisibleRect`).
    public var museVisibleRect: CGRect {
        get { compositor.museVisibleRect }
        set { compositor.museVisibleRect = newValue }
    }

    /// Swaps both slots and both visible rects in one step, so no frame pairs a new slot with an old
    /// rect (`CompositorManager.setLayerPlacement`).
    public func setLayerPlacement(
        avatarSlot: AvatarSlot, avatarVisibleRect: CGRect, museSlot: AvatarSlot, museVisibleRect: CGRect
    ) {
        compositor.setLayerPlacement(
            avatarSlot: avatarSlot, avatarVisibleRect: avatarVisibleRect,
            museSlot: museSlot, museVisibleRect: museVisibleRect)
    }

    public var watermarkEnabled: Bool {
        get { compositor.watermarkEnabled }
        set { compositor.watermarkEnabled = newValue }
    }

    public var watermarkPosition: WatermarkPosition {
        get { compositor.watermarkPosition }
        set { compositor.watermarkPosition = newValue }
    }

    public var watermarkOpacity: Float {
        get { compositor.watermarkOpacity }
        set { compositor.watermarkOpacity = newValue }
    }

    /// Enable floating head mode (person segmentation with transparent background)
    public var floatingHeadEnabled: Bool {
        get { compositor.floatingHeadEnabled }
        set { compositor.floatingHeadEnabled = newValue }
    }

    /// Scene overlay text (e.g. "Starting Soon...", "Be Right Back"). Set nil to clear.
    public var sceneOverlayText: String? {
        get { compositor.sceneOverlayText }
        set { compositor.sceneOverlayText = newValue }
    }

    /// Scene overlay SF Symbol icon name. Set nil for no icon.
    public var sceneOverlayIcon: String? {
        get { compositor.sceneOverlayIcon }
        set { compositor.sceneOverlayIcon = newValue }
    }

    /// Scene overlay gradient colors. Set nil for default blue-purple gradient.
    public var sceneOverlayGradientColors: (start: CGColor, end: CGColor)? {
        get { compositor.sceneOverlayGradientColors }
        set { compositor.sceneOverlayGradientColors = newValue }
    }

    nonisolated(unsafe) public var enableCamera: Bool = true
    nonisolated(unsafe) public var enableMicrophone: Bool = true
    nonisolated(unsafe) public var enableDesktop: Bool = true
    nonisolated(unsafe) public var enableAvatar: Bool = false
    nonisolated(unsafe) public var selectedDisplayID: CGDirectDisplayID?

    /// Computed input mode based on current toggle states
    public var inputMode: RecordingInputMode {
        if enableDesktop {
            if enableCamera && enableMicrophone { return .desktopWithCameraAndMic }
            if enableCamera { return .desktopWithCamera }
            if enableAvatar && enableMicrophone { return .desktopWithCameraAndMic } // Avatar as camera PiP
            if enableAvatar { return .desktopWithCamera }
            if enableMicrophone { return .desktopWithMic }
            return .desktopOnly
        } else if enableCamera {
            if enableMicrophone { return .cameraWithMic }
            return .cameraOnly
        } else if enableAvatar {
            if enableMicrophone { return .avatarWithMic }
            return .avatarOnly
        } else if enableMicrophone {
            return .audioOnly
        }
        // Default fallback
        return .desktopOnly
    }

    /// Provider for VRM avatar texture frames (set by AvatarViewModel when avatar mode is active)
    nonisolated(unsafe) public var avatarTextureProvider: (@Sendable () -> CVPixelBuffer?)?

    /// Provider for Muse AI avatar texture frames (for dual avatar mode)
    nonisolated(unsafe) public var museTextureProvider: (@Sendable () -> CVPixelBuffer?)?

    /// Register a Muse TTS audio source for mixing into the stream
    public func addMuseAudioSource(_ source: AudioSource) {
        audioRouter.addSource(source)
        syncAudioMixerRouting()
    }

    /// Mirrors the router's sources into the mixer and pins the microphone as the mix clock when present.
    /// Without a pin the first source to deliver (screen audio, say) would set the cadence.
    private func syncAudioMixerRouting() {
        let ids = audioRouter.allSourceIDs
        for id in ids { audioMixer.registerSource(id) }
        if ids.contains("microphone") { audioMixer.setClockSource("microphone") }
    }

    /// The audio inputs the encoder pre-creates for a recording whose router holds `routerSourceIDs`.
    /// Every router source reaches the encoder through the mixer, so the file gets one track: the mix.
    nonisolated static func encoderAudioTrackIDs(forRouterSources routerSourceIDs: [String]) -> [String] {
        routerSourceIDs.isEmpty ? [] : [AudioMixer.outputSourceID]
    }

    /// Router sources the current settings no longer want. The microphone and screen audio
    /// follow the settings; other sources (the Muse voice) belong to whoever added them.
    nonisolated static func unwantedAudioSourceIDs(in routerSourceIDs: [String], microphone: Bool, screenAudio: Bool) -> [String] {
        routerSourceIDs.filter { ($0 == "microphone" && !microphone) || ($0 == "screen" && !screenAudio) }
    }

    /// Stops and removes the microphone or screen audio when the settings turned it off.
    /// A session is reused, so a source added for an earlier recording or stream would
    /// otherwise be started again and captured.
    private func removeUnwantedAudioSources(microphone: Bool) async {
        let unwanted = Self.unwantedAudioSourceIDs(
            in: audioRouter.allSourceIDs, microphone: microphone, screenAudio: enableScreenAudio
        )
        for sourceID in unwanted {
            await audioRouter.stopAndRemoveSource(sourceID)
            audioMixer.unregisterSource(sourceID)
        }
    }

    /// Adds a microphone that reports its level as `audioLevel`.
    private func addMicrophone() {
        let microphone = audioInputs.makeMicrophone()
        (microphone as? MicrophoneAudioSource)?.onLevelUpdate = { @Sendable [weak self] level in
            self?.audioLevel = level
        }
        audioRouter.addSource(microphone)
    }

    /// Drops queued audio and the clock choice so nothing carries over between sessions.
    private func resetAudioMixer() {
        audioMixer.reset()
        syncAudioMixerRouting()
    }

    /// Every audio source registered with the router (tests: Creator CRE-233).
    public var registeredAudioSourceIDs: [String] { audioRouter.allSourceIDs }

    /// Timer for driving frame capture in non-desktop modes
    nonisolated(unsafe) private var cameraFrameTimer: Timer?
    /// Whether a frame the 30 fps timer started is still composing or encoding.
    private let drivenFrameInFlight = OSAllocatedUnfairLock(initialState: false)

    /// Debug logging throttle
    nonisolated(unsafe) private var lastDebugLogTime: Date?

    /// Standard canvas size for camera/avatar-only modes (1080p)
    private let standardCanvasSize = CGSize(width: 1920, height: 1080)

    public var cameraSourceIdentifiers: [String] = []
    public var cameraLayoutStrategy: MultiCameraLayout = .pictureInPicture
    public var metadataHandler: (@Sendable (CameraMetadataEvent) -> Void)?
    public var previewHandler: (@Sendable (CameraPreviewEvent) -> Void)?
    /// Invoked once per camera source that fails to start (device missing, in use by another
    /// app, not authorized, ...). Called on the main actor from `startCameraPreview(for:)`.
    /// When every requested source fails, `startCameraPreview(for:)` additionally throws
    /// `RecorderError.allCameraSourcesFailed`.
    public var cameraStartFailureHandler: (@Sendable (CameraStartFailure) -> Void)?
    /// Called on the main actor when screen capture can't switch to the selected display, e.g.
    /// `RecorderError.cannotAddInput` after `startScreenPreview()`. The display captured before,
    /// if any, keeps capturing.
    public var screenCaptureFailureHandler: (@MainActor (any Error) -> Void)?
    nonisolated(unsafe) public var screenPreviewHandler: (@Sendable (CGImage) -> Void)?
    public var remoteSourcesHandler: (@Sendable ([String]) -> Void)?
    /// Handler for monitor frames - receives the final composed frame before encoding
    nonisolated(unsafe) public var monitorFrameHandler: (@Sendable (CVPixelBuffer, CMTime) -> Void)?

    // MARK: - Initialization

    public convenience init() throws {
        try self.init(screenCapture: ScreenCaptureManager())
    }

    init(
        screenCapture: ScreenCaptureManager,
        encoder: VideoEncoder = VideoEncoder(),
        audioInputs: AudioInputs = .system
    ) throws {
        self.screenCapture = screenCapture
        self.audioInputs = audioInputs
        self.cameraCaptures = [:]
        self.audioRouter = AudioRouter()
        self.audioMixer = AudioMixer(voiceSourceID: "muse-voice")
        self.compositor = try CompositorManager()
        self.encoder = encoder

        setupCapture()
        screenCapture.onCaptureError = { [weak self] error in self?.screenCaptureFailureHandler?(error) }
    }

    // MARK: - Setup

    private nonisolated func setupCapture() {
        // Wire up screen capture
        screenCapture.onFrameForCapture = { @Sendable [weak self] screenBuffer, captureID in
            guard let self else { return }
            // Keep the consumer associated with this frame, even if the source changes
            // while composition is suspended waiting for the main actor.
            let monitorHandler = self.monitorFrameHandler
            // Process asynchronously to handle encoding
            // Note: CMSampleBuffer is not Sendable, but we process it immediately without retaining
            Task {
                await self.processScreenFrame(screenBuffer, captureID: captureID, monitorHandler: monitorHandler)
            }
        }

        // Wire up audio router through mixer for multi-source mixing (mic + TTS)
        audioRouter.onConvertedSample = { @Sendable [weak self] audioSample, sourceID in
            guard let self else { return }
            self.audioMixer.addSample(audioSample, from: sourceID)
        }

        // Wire mixer output to encoder
        audioMixer.onMixedSample = { @Sendable [weak self] mixedSample in
            self?.mixedAudioDelivery.enqueue { [weak self] in
                await self?.processAudioSampleSync(mixedSample, sourceID: AudioMixer.outputSourceID)
            }
        }
    }

    // MARK: - Recording Control

    /// Starts a new recording session. Returns at once while a recording is running. A call made
    /// while another is still starting waits for it, and returns or throws as it does; its own
    /// URL and title are not used.
    public func startRecording(outputURL: URL, title: String) async throws {
        if startJoiners != nil {
            try await withCheckedThrowingContinuation { startJoiners?.append($0) }
            return
        }
        guard !_isRecording else { return }
        startJoiners = []
        do {
            try await startRecordingOnce(outputURL: outputURL, title: title)
        } catch {
            endStart(with: .failure(error))
            throw error
        }
        endStart(with: .success(()))
    }

    /// Hands a start's outcome to the calls that joined it.
    private func endStart(with outcome: Result<Void, any Error>) {
        let joiners = startJoiners ?? []
        startJoiners = nil
        for joiner in joiners { joiner.resume(with: outcome) }
    }

    private func startRecordingOnce(outputURL: URL, title: String) async throws {
        recordingStarting = true
        do {
            try await beginRecording(outputURL: outputURL, title: title)
        } catch {
            // Both cleared before the sources stop. This start owns nothing from here on, so
            // during that await a stream that ends releases the sources itself, and a stream that
            // starts doesn't see this start's claim on them. (A startRecording made meanwhile
            // joins this start and gets its failure.)
            let streamLeftSources = streamLeftSourcesToStartingRecording
            recordingStarting = false
            streamLeftSourcesToStartingRecording = false
            // A stream that ended meanwhile left its sources to this recording; nothing owns them now.
            if streamLeftSources && !_streamingActive.withLock({ $0 }) {
                await stopSources()
                resetAudioMixer()
                // A stream that started during that await started its frames, but the screen and
                // cameras had already stopped, and the audio it started may have been stopped too.
                if _streamingActive.withLock({ $0 }) {
                    restartSourcesForStream()
                }
            }
            throw error
        }
        recordingStarting = false
        streamLeftSourcesToStartingRecording = false
    }

    private func beginRecording(outputURL: URL, title: String) async throws {
        let mode = inputMode

        // Validate at least one input is enabled
        guard enableDesktop || enableCamera || enableAvatar || enableMicrophone else {
            throw RecorderError.permissionDenied // No inputs enabled
        }

        // Request permissions based on mode
        guard await requestPermissions() else {
            throw RecorderError.permissionDenied
        }

        // Clear any previous source registrations
        await sourceRegistry.clear()

        // STEP 1: Register all required capture sources
        print("📋 [RecordingSession] Registering capture sources...")

        // Register screen capture if desktop mode
        if mode.needsDesktop {
            let displayID = selectedDisplayID
            let screenSource = RegisteredSource(
                sourceID: "screen",
                sourceType: .screen,
                start: { [screenCapture] in
                    try await screenCapture.startCaptureAndWaitForFirstFrame(displayID: displayID)
                }
            )
            await sourceRegistry.register(screenSource)
        }

        // Register camera captures - check enableCamera directly, not mode.needsCamera
        // This allows camera+avatar to work together in the multi-source architecture
        if enableCamera {
            try await registerCameraSources()
        }

        // Register avatar capture if enabled
        print("🎭 [RecordingSession] Avatar check: enableAvatar=\(enableAvatar), provider=\(avatarTextureProvider != nil ? "SET" : "NIL")")
        if enableAvatar, let provider = avatarTextureProvider {
            let avatarSource = RegisteredSource(
                sourceID: "avatar",
                sourceType: .avatar,
                start: {
                    try await AvatarCaptureHelper.waitForFirstFrame(provider: provider)
                }
            )
            await sourceRegistry.register(avatarSource)
            print("🎭 [RecordingSession] Avatar source registered")
        } else if enableAvatar {
            print("⚠️ [RecordingSession] Avatar enabled but no texture provider set!")
        }

        // STEP 2: Add audio sources to audio router (but don't start yet)
        await removeUnwantedAudioSources(microphone: mode.needsMicrophone)
        // A live stream's mix carries on into the recording: resetting it would drop its queued
        // audio and clock choice mid-stream, a dropout while sources build their lead again.
        if !_streamingActive.withLock({ $0 }) {
            resetAudioMixer()
        }
        // A stream that outlived the last recording still runs its microphone and screen audio;
        // the recording takes those over rather than adding a second of each.
        if mode.needsMicrophone && !audioRouter.allSourceIDs.contains("microphone") {
            addMicrophone()
            syncAudioMixerRouting()
        }

        // Add desktop/screen audio if enabled
        if enableScreenAudio && !audioRouter.allSourceIDs.contains("screen") {
            audioRouter.addSource(audioInputs.makeScreenAudio())
            syncAudioMixerRouting()
        }

        // STEP 3: Start encoder FIRST with pre-created audio tracks for all sources
        let audioSourceIDs = Self.encoderAudioTrackIDs(forRouterSources: audioRouter.allSourceIDs)
        print("🎙️ RecordingSession: Creating encoder with audio tracks for: \(audioSourceIDs)")
        try await encoder.startRecording(to: outputURL, title: title, audioSourceIDs: audioSourceIDs, videoEnabled: mode.needsVideo)
        print("🎙️ RecordingSession: Encoder started and ready")

        // STEP 4: Start all capture sources and WAIT for readiness
        print("⏳ [RecordingSession] Starting all capture sources and waiting for readiness...")
        let result = await sourceRegistry.startAllAndWaitForReady(timeout: 5.0)

        switch result {
        case .allReady:
            print("✅ [RecordingSession] All capture sources ready!")
        case .partialReady(let failed):
            for (id, error) in failed {
                print("⚠️ [RecordingSession] Source '\(id)' failed: \(error)")
            }
            // Continue with available sources (graceful degradation)
        }

        // Brief yield to ensure any pending MainActor buffer updates complete
        // This handles the race between capture callbacks and buffer storage
        await Task.yield()

        // STEP 5: NOW mark recording as active (all sources are ready)
        _isRecording = true
        recordingStartTime = .now
        pauseStartTime = nil
        pausedDuration = .zero
        updateComposedPreviewDriver()

        // STEP 6: Start audio sources (after encoder is ready to receive samples)
        print("🎙️ RecordingSession: Starting all audio sources...")
        try? await audioRouter.startAll()
        print("🎙️ RecordingSession: Audio sources started. Active sources: \(audioRouter.activeSourceIDs)")

        // Start camera/avatar frame driver if not using desktop (no screen capture to drive timing)
        if !mode.needsDesktop && mode.needsVideo {
            startCameraFrameDriver()
        }

        print("🎬 [RecordingSession] Recording started successfully!")
    }

    /// Register camera sources with the registry
    private func registerCameraSources() async throws {
        let identifiers = effectiveCameraIdentifiers()
        guard enableCamera, !identifiers.isEmpty else { return }

        // Determine which cameras to stop and which to start
        let currentIDs = Set(cameraCaptures.keys)
        let requestedIDs = Set(identifiers).subtracting(remoteCameraIdentifiers)

        let toStop = currentIDs.subtracting(requestedIDs)
        let toStart = requestedIDs.subtracting(currentIDs)

        // Stop cameras that are no longer needed
        for identifier in toStop {
            if let manager = cameraCaptures.removeValue(forKey: identifier) {
                manager.stopCapture()
            }
            latestCameraBuffers.removeValue(forKey: identifier)
            latestCameraMetadata.removeValue(forKey: identifier)
        }

        // Create new camera managers
        for identifier in toStart {
            let manager = CameraManager()
            manager.onFrame = { [weak self] buffer in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.latestCameraBuffers[identifier] = buffer
                    self.dispatchPreview(for: identifier, buffer: buffer)
                }
            }
            cameraCaptures[identifier] = manager
        }

        // Register all active cameras with the registry
        for (identifier, manager) in cameraCaptures {
            let cameraSource = RegisteredSource(
                sourceID: "camera-\(identifier)",
                sourceType: .camera,
                start: { [manager] in
                    try await manager.startCaptureAndWaitForFirstFrame(with: identifier)
                }
            )
            await sourceRegistry.register(cameraSource)
        }
    }

    /// Stops the current recording session.
    ///
    /// Stops the frame driver and the screen, camera and audio captures. While a stream is live,
    /// only the file finishes: they keep feeding the stream as before, until `stopStreaming()`
    /// stops them, or until the file is finished if the stream ends first. Frames and audio that
    /// arrive while the file is being finished go to the stream only; the encoder takes nothing
    /// more into the file once finishing has begun. A stream that starts while this stops the
    /// sources, or while the file finishes, gets them back once the recording is over.
    public func stopRecording() async throws -> URL {
        let streamKeepsSources = _streamingActive.withLock { $0 }
        // A stream that starts once this has stopped the sources finds the recording still
        // running, so it neither starts them nor its frames: this does once the recording is over.
        var stoppedSources = false
        if !streamKeepsSources {
            await stopSources()
            stoppedSources = true
        }
        if !_streamingActive.withLock({ $0 }) {
            // Nothing arrives now. Emit what the mixer still holds (a sound shorter than its
            // prefill, a source's buffered tail) and let it reach the encoder before the file
            // closes. A stream that continues keeps the mixer running instead, including one
            // that started while the sources were stopping.
            audioMixer.drain()
            await mixedAudioDelivery.waitUntilDelivered()
            resetAudioMixer()
        }

        // The recording is over even when finishing the file fails
        defer {
            _isRecording = false
            recordingStartTime = nil
            pauseStartTime = nil
            pausedDuration = .zero
            // No await since the check: a stream that starts after it sees no recording and
            // starts its sources and frames itself.
            if stoppedSources && _streamingActive.withLock({ $0 }) {
                restartSourcesForStream()
            }
            inputsDidChange()
        }

        // Finish encoding
        let finished: Result<URL, any Error>
        do {
            finished = .success(try await encoder.finishRecording())
        } catch {
            finished = .failure(error)
        }
        // A stream that ended while the file finished left its sources running for the recording.
        if streamKeepsSources && !_streamingActive.withLock({ $0 }) {
            await stopSources()
            resetAudioMixer()
            stoppedSources = true
        }
        let result = try finished.get()

        print("🛑 [RecordingSession] Recording stopped")

        return result
    }

    /// Starts what a live stream needs after `stopSources()`: the screen capture in desktop
    /// modes and the cameras (a stream that starts by itself uses the running previews), then
    /// the frame driver and the audio, as starting the stream does.
    private func restartSourcesForStream() {
        if inputMode.needsDesktop {
            do {
                try screenCapture.startCapture(displayID: selectedDisplayID)
            } catch {
                screenCaptureFailureHandler?(error)
            }
        }
        // stopSources() removed the cameras too; without them a camera stream composes none.
        // Each camera that fails is reported to cameraStartFailureHandler, as in a preview.
        if enableCamera {
            try? startCameraCapturesIfNeeded()
        }
        startStreamingFrameGeneration()
    }

    /// Stops the frame driver and every capture: the screen, the cameras and the audio.
    private func stopSources() async {
        stopCameraFrameDriver()
        screenCapture.stopCapture()
        stopCameraCaptures()
        try? await audioRouter.stopAll()
    }

    /// Pauses the current recording
    public func pauseRecording() {
        guard _isRecording, pauseStartTime == nil else { return }
        pauseStartTime = .now
        Task {
            await encoder.pause()
        }
    }

    /// Resumes a paused recording
    public func resumeRecording() {
        guard _isRecording, let pauseStartTime else { return }
        pausedDuration += pauseStartTime.duration(to: .now)
        self.pauseStartTime = nil
        Task {
            await encoder.resume()
        }
    }

    // MARK: - Private Methods

    private func requestPermissions() async -> Bool {
        // Always need screen recording permission (handled by system)

        if enableCamera {
            guard await CameraManager.requestPermission() else {
                return false
            }
        }

        if enableMicrophone {
            guard await audioInputs.microphonePermission() else {
                return false
            }
        }

        return true
    }

    nonisolated(unsafe) private var latestCameraBuffers: [String: CMSampleBuffer] = [:]

    private nonisolated func processScreenFrame(_ screenBuffer: CMSampleBuffer, captureID: UUID, monitorHandler: MonitorHandler?) async {
        guard screenCapture.isCurrentCapture(captureID) else { return }
        // Dispatch screen preview if handler is set
        if let handler = screenPreviewHandler,
           let pixelBuffer = CMSampleBufferGetImageBuffer(screenBuffer) {
            var cgImage: CGImage?
            let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
            if status == noErr, let cgImage {
                handler(cgImage)
            }
        }

        await processFrameSync(screen: screenBuffer, captureID: captureID, monitorHandler: monitorHandler)
    }

    private nonisolated func processFrameSync(screen screenBuffer: CMSampleBuffer, captureID: UUID, monitorHandler: MonitorHandler?) async {
        guard let delivery = beginFrameDelivery(handler: monitorHandler) else { return }
        var delivered = false
        defer { finishFrameDelivery(delivery, delivered: delivered) }

        let mode = await MainActor.run { self.inputMode }

        // Desktop modes use screen as base
        guard mode.needsDesktop else { return }

        // Capture state on MainActor to ensure thread safety
        let (cameraLayers, isAvatarEnabled, provider, museProvider, _) = await MainActor.run {
            (
                self.cameraLayersForComposition(),
                self.enableAvatar,
                self.avatarTextureProvider,
                self.museTextureProvider,
                self.enableCamera
            )
        }

        // Get avatar texture if avatar mode is enabled
        let avatarTexture: CVPixelBuffer?
        if isAvatarEnabled, let provider {
            avatarTexture = provider()
        } else {
            avatarTexture = nil
        }

        // Get muse texture if muse mode is enabled
        let museTexture: CVPixelBuffer? = museProvider?()

        guard let composited = compositor.composite(
            screen: screenBuffer,
            cameraLayers: cameraLayers,
            avatarTexture: avatarTexture,
            museTexture: museTexture
        ) else {
            return
        }

        // Encode the composited frame
        let timestamp = CMSampleBufferGetPresentationTimeStamp(screenBuffer)

        guard screenCapture.isCurrentCapture(captureID), isCurrent(delivery) else { return }
        delivery.handler?(composited, timestamp)
        delivered = true

        if delivery.previewGeneration == nil {
            await encoder.encodeVideoFrame(composited, timestamp: timestamp)
        }
    }

    /// Processes a frame for camera-only or avatar-only modes (called by timer)
    private nonisolated func processCameraOrAvatarFrame() async {
        let monitorHandler = monitorFrameHandler
        guard let delivery = beginFrameDelivery(handler: monitorHandler) else { return }
        var delivered = false
        defer { finishFrameDelivery(delivery, delivered: delivered) }

        let mode = await MainActor.run { self.inputMode }
        let canvasSize = standardCanvasSize

        var composited: CVPixelBuffer?
        var timestamp: CMTime
        let museTexture: CVPixelBuffer? = museTextureProvider?()

        switch mode {
        case .cameraWithMic, .cameraOnly:
            // Camera-only modes: use first camera as primary, others as PiP
            let cameraLayers = await MainActor.run { self.cameraLayersForComposition() }
            guard !cameraLayers.isEmpty,
                  let firstBuffer = cameraLayers.first?.buffer
            else { return }

            composited = compositor.composite(
                cameraLayers: cameraLayers,
                canvasSize: canvasSize,
                museTexture: museTexture
            )
            timestamp = CMSampleBufferGetPresentationTimeStamp(firstBuffer)

        case .avatarWithMic, .avatarOnly:
            // Avatar modes: use avatar texture as primary
            guard let provider = avatarTextureProvider,
                  let avatarTexture = provider()
            else { return }

            let cameraLayers = await MainActor.run { self.cameraLayersForComposition() }
            composited = compositor.composite(
                avatarTexture: avatarTexture,
                cameraLayers: cameraLayers,
                museTexture: museTexture
            )
            timestamp = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)

        default:
            // Desktop modes are handled by processFrameSync, audio-only has no video
            return
        }

        guard let output = composited else { return }

        guard isCurrent(delivery) else { return }
        delivery.handler?(output, timestamp)
        delivered = true

        if delivery.previewGeneration == nil {
            await encoder.encodeVideoFrame(output, timestamp: timestamp)
        }
    }

    /// The idle path has its own admission gate: it never enters the encoder or starts
    /// audio, and all sources together compose at most one preview frame per second.
    private nonisolated func beginFrameDelivery(handler: MonitorHandler?) -> FrameDelivery? {
        if _isRecording || _streamingActive.withLock({ $0 }) {
            return FrameDelivery(handler: handler, previewGeneration: nil)
        }
        return composedPreview.withLock { state in
            guard state.enabled, !state.inFlight, handler != nil else { return nil }
            let now = ContinuousClock.now
            if let last = state.lastFrameTime, last.duration(to: now) < .seconds(1) { return nil }
            state.inFlight = true
            return FrameDelivery(handler: handler, previewGeneration: state.generation)
        }
    }

    /// Ends an idle preview frame. Only a frame handed to the handler counts toward the 1 s
    /// gate. A frame a source change superseded while it composed starts its replacement at
    /// once: the change's own immediate frame was refused while this one was in flight.
    private nonisolated func finishFrameDelivery(_ delivery: FrameDelivery, delivered: Bool) {
        guard let generation = delivery.previewGeneration else { return }
        let superseded = composedPreview.withLock { state in
            state.inFlight = false
            if delivered { state.lastFrameTime = .now }
            return !delivered && state.enabled && state.generation != generation
        }
        guard superseded else { return }
        Task { @MainActor [weak self] in
            guard let self, !self._isRecording, !self._streamingActive.withLock({ $0 }),
                  !self.inputMode.needsDesktop, self.inputMode.needsVideo else { return }
            await self.processCameraOrAvatarFrame()
        }
    }

    private nonisolated func isCurrent(_ delivery: FrameDelivery) -> Bool {
        guard let generation = delivery.previewGeneration else { return true }
        return composedPreview.withLock { $0.enabled && $0.generation == generation }
    }

    private func updateComposedPreviewDriver() {
        composedPreviewTimer?.invalidate()
        composedPreviewTimer = nil
        let enabled = composedPreview.withLock { state in
            state.generation &+= 1
            return state.enabled
        }
        guard enabled, !_isRecording, !_streamingActive.withLock({ $0 }),
              !inputMode.needsDesktop, inputMode.needsVideo else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            Task { @MainActor [weak self] in await self?.processCameraOrAvatarFrame() }
        }
        composedPreviewTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        Task { [weak self] in await self?.processCameraOrAvatarFrame() }
    }

    // MARK: - Camera/Avatar Frame Driver

    /// Starts a timer to drive frame capture at 30fps for non-desktop modes.
    ///
    /// One frame at a time: a tick that comes while the previous frame is still composing or
    /// encoding is skipped, so a slow composite lowers the frame rate instead of queueing frames.
    private func startCameraFrameDriver() {
        stopCameraFrameDriver()

        let inFlight = drivenFrameInFlight
        cameraFrameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            let admitted = inFlight.withLock { busy in
                guard !busy else { return false }
                busy = true
                return true
            }
            guard admitted else { return }
            Task { @MainActor [weak self] in
                await self?.processCameraOrAvatarFrame()
                inFlight.withLock { $0 = false }
            }
        }
    }

    /// Re-evaluates frame generation after a source toggle during a recording or stream.
    /// Camera and avatar modes are driven by the 30 fps frame timer, desktop modes by screen
    /// frames; without this a live session kept the mode it started in. For a desktop mode,
    /// start the screen capture first (e.g. `startScreenPreview()`): this stops the frame
    /// timer, and the screen frames then carry the output.
    public func inputsDidChange() {
        updateComposedPreviewDriver()
        guard _isRecording || _streamingActive.withLock({ $0 }) else {
            stopCameraFrameDriver()
            return
        }
        let mode = inputMode
        if !mode.needsDesktop && mode.needsVideo {
            if cameraFrameTimer == nil { startCameraFrameDriver() }
        } else {
            stopCameraFrameDriver()
        }
    }

    /// Stops the camera/avatar frame driver
    private func stopCameraFrameDriver() {
        cameraFrameTimer?.invalidate()
        cameraFrameTimer = nil
    }

    private nonisolated func processAudioSampleSync(_ audioSample: CMSampleBuffer, sourceID: String) async {
        guard _isRecording || _streamingActive.withLock({ $0 }) else {
            return
        }

        // Encode audio with source ID for multi-track support
        await encoder.encodeAudioSample(audioSample, sourceID: sourceID)
    }

    // MARK: - Public Utilities

    /// Enables final composed monitor frames at most once per second while idle.
    /// Callers configure/start their existing visual previews and call `inputsDidChange()`
    /// after changing sources. This starts no capture, audio, recording or streaming;
    /// disabling it leaves an active recording or stream's normal frame cadence intact.
    public func setComposedPreviewEnabled(_ enabled: Bool) {
        let changed = composedPreview.withLock { state in
            guard state.enabled != enabled else { return false }
            state.enabled = enabled
            return true
        }
        if changed { updateComposedPreviewDriver() }
    }

    /// Get available screens
    public static func availableScreens() -> [ScreenInfo] {
        return ScreenCaptureManager.availableScreens()
    }

    /// Get available cameras
    public static func availableCameras() -> [CameraInfo] {
        return CameraManager.availableCameras()
    }

    /// Get available microphones
    public static func availableMicrophones() -> [AudioDeviceInfo] {
        return MicrophoneAudioSource.availableMicrophones()
    }

    // MARK: - Audio Source Management

    /// Enable screen audio capture (macOS only).
    /// Set before calling startRecording() or startStreaming().
    nonisolated(unsafe) public var enableScreenAudio: Bool = false

    /// Get audio router for advanced audio source management
    public var audioSourceRouter: AudioRouter {
        audioRouter
    }

    /// Set volume gain for an audio source (0.0 = silent, 1.0 = full)
    public nonisolated func setAudioGain(_ gain: Float, for sourceID: String) {
        audioMixer.setGain(gain, for: sourceID)
    }

    /// Get camera preview session (first active camera if available)
    public func getCameraPreview() -> AVCaptureSession? {
        return cameraCaptures.values.first?.getPreviewSession()
    }

    /// Starts camera capture purely for preview purposes (no recording).
    ///
    /// Each source that fails to start is reported through `cameraStartFailureHandler`.
    /// Throws `RecorderError.allCameraSourcesFailed` when none of the requested sources
    /// is running afterwards; if at least one is, this returns normally.
    public func startCameraPreview(for identifiers: [String]) throws {
        cameraSourceIdentifiers = Array(identifiers.prefix(MultiCameraLayout.maxSupportedSources))
        enableCamera = true
        try startCameraCapturesIfNeeded()
    }

    /// Stops any preview camera capture sessions.
    public func stopCameraPreview() {
        stopCameraCaptures()
    }

    /// Starts screen capture purely for preview purposes (no recording).
    public func startScreenPreview() throws {
        try screenCapture.startCapture(displayID: selectedDisplayID)
    }

    /// Stops screen preview capture.
    public func stopScreenPreview() {
        screenCapture.stopCapture()
    }

    /// Start frame generation for streaming-only mode (no recording to file).
    /// In camera/avatar modes, starts the 30fps frame driver timer.
    /// In desktop modes, screen capture is already running from preview — frames will now
    /// pass through processFrameSync since streaming is active.
    /// Also starts audio routing so mic audio reaches the encoder.
    private func startStreamingFrameGeneration() {
        updateComposedPreviewDriver()
        let mode = inputMode

        // Start camera/avatar frame driver if not using desktop capture
        if !mode.needsDesktop && mode.needsVideo {
            startCameraFrameDriver()
        }

        // Fresh mixer state for this stream (before any audio source starts delivering)
        resetAudioMixer()

        // Add audio sources if not already added (streaming without recording). This runs after
        // the call returns, so the stream may have stopped before or while its audio starts.
        Task { @MainActor in
            await removeUnwantedAudioSources(microphone: mode.needsMicrophone)
            guard _streamingActive.withLock({ $0 }) else { return }
            if mode.needsMicrophone && !audioRouter.allSourceIDs.contains("microphone") {
                addMicrophone()
            }
            if enableScreenAudio && !audioRouter.allSourceIDs.contains("screen") {
                audioRouter.addSource(audioInputs.makeScreenAudio())
            }
            syncAudioMixerRouting()
            try? await audioRouter.startAll()
            // A stop that came while the sources were starting stopped only those running then.
            if !_streamingActive.withLock({ $0 }) && !_isRecording && !recordingStarting {
                try? await audioRouter.stopAll()
            }
        }

        print("📡 Started frame generation for streaming (mode: \(mode))")
    }

    // MARK: - Streaming

    /// Start streaming to a single RTMP destination
    public func startStreaming(to destination: RTMPPublisher.Destination, streamKey: String) async throws {
        try await encoder.startStreaming(to: destination, streamKey: streamKey)
        _streamingActive.withLock { $0 = true }
        if !_isRecording {
            startStreamingFrameGeneration()
        }
    }

    /// Start streaming to multiple RTMP destinations simultaneously (simulcast)
    public func startStreaming(destinations: [(id: String, destination: RTMPPublisher.Destination, streamKey: String)]) async throws {
        try await encoder.startStreaming(to: destinations)
        _streamingActive.withLock { $0 = true }
        if !_isRecording {
            startStreamingFrameGeneration()
        }
    }

    /// Start NTDF-encrypted streaming to Arkavo
    /// - Parameters:
    ///   - kasURL: KAS URL for key access (e.g., https://platform.arkavo.net)
    ///   - rtmpURL: RTMP server URL (e.g., rtmp://platform.arkavo.net:1935)
    ///   - streamKey: Stream key (e.g., live/test)
    public func startNTDFStreaming(kasURL: URL, rtmpURL: String, streamKey: String) async throws {
        try await encoder.startNTDFStreaming(kasURL: kasURL, rtmpURL: rtmpURL, streamKey: streamKey)
        _streamingActive.withLock { $0 = true }
        // Start frame generation if not already recording
        if !_isRecording {
            startStreamingFrameGeneration()
        }
    }

    /// Tests: the mixer every audio source reaches the encoder through.
    var audioMixerForTesting: AudioMixer { audioMixer }

    /// Tests: `startStreaming(to:streamKey:)` without RTMP. The encoder's stream output goes to
    /// `onEncodedVideo` instead of a destination; `stopStreaming()` ends it.
    func startStreamingForTesting(onEncodedVideo: @escaping @Sendable (EncodedVideoFrame) -> Void) async throws {
        try await encoder.startStreamingForTesting(onEncodedVideo: onEncodedVideo)
        _streamingActive.withLock { $0 = true }
        if !_isRecording {
            startStreamingFrameGeneration()
        }
    }

    /// Stop streaming to all destinations.
    ///
    /// With no recording running, this also stops the frame driver and the screen, camera and
    /// audio captures, as stopping a recording does with no stream. A recording keeps them.
    public func stopStreaming() async {
        _streamingActive.withLock { $0 = false }
        await encoder.stopStreaming()
        await encoder.stopNTDFStreaming()
        await streamDidEnd()
    }

    /// Stop streaming to a single destination (others continue). Stopping the last one ends the
    /// stream as `stopStreaming()` does.
    public func stopStreaming(id: String) async {
        await encoder.stopStreaming(id: id)
        // If no destinations remain, deactivate streaming
        if await encoder.activeDestinationIds.isEmpty {
            _streamingActive.withLock { $0 = false }
            await streamDidEnd()
        }
    }

    /// With no recording running or starting either, nothing uses the sources any more.
    private func streamDidEnd() async {
        if recordingStarting {
            streamLeftSourcesToStartingRecording = true
        } else if !_isRecording {
            await stopSources()
            resetAudioMixer()
        }
        inputsDidChange()
    }

    /// Get streaming statistics
    public var streamStatistics: RTMPPublisher.StreamStatistics? {
        get async {
            return await encoder.streamStatistics
        }
    }

    /// Check if currently streaming
    public var isStreaming: Bool {
        get async {
            if let stats = await encoder.streamStatistics {
                return stats.framesSent > 0
            }
            return false
        }
    }

    // MARK: - Camera Management

    public func setCameraSources(_ identifiers: [String]) {
        cameraSourceIdentifiers = Array(identifiers.prefix(MultiCameraLayout.maxSupportedSources))
    }

    private func startCameraCapturesIfNeeded() throws {
        let identifiers = effectiveCameraIdentifiers()
        guard enableCamera, !identifiers.isEmpty else {
            stopCameraCaptures()
            return
        }

        // Determine which cameras to stop and which to start
        let currentIDs = Set(cameraCaptures.keys)
        let requestedIDs = Set(identifiers).subtracting(remoteCameraIdentifiers)

        let toStop = currentIDs.subtracting(requestedIDs)
        let toStart = requestedIDs.subtracting(currentIDs)

        // If nothing changed, skip the expensive restart
        if toStop.isEmpty && toStart.isEmpty {
            return
        }

        // Stop only cameras that are no longer needed
        for identifier in toStop {
            if let manager = cameraCaptures.removeValue(forKey: identifier) {
                manager.stopCapture()
            }
            latestCameraBuffers.removeValue(forKey: identifier)
            latestCameraMetadata.removeValue(forKey: identifier)
        }

        // Start only new cameras
        var failures: [CameraStartFailure] = []
        for identifier in toStart {
            let manager = CameraManager()
            manager.onFrame = { [weak self] buffer in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.latestCameraBuffers[identifier] = buffer
                    self.dispatchPreview(for: identifier, buffer: buffer)
                }
            }
            do {
                try manager.startCapture(with: identifier)
                cameraCaptures[identifier] = manager
            } catch {
                // Don't keep a dead manager around: getCameraPreview() would hand out a
                // non-running session and the next start would skip it as "unchanged".
                manager.stopCapture()
                let failure = CameraStartFailure(sourceID: identifier, error: error)
                print("⚠️ [RecordingSession] Failed to start camera \(identifier): \(failure.message) (\(error))")
                failures.append(failure)
            }
        }

        for failure in failures {
            cameraStartFailureHandler?(failure)
        }

        // Cameras that were already running count as success, so check the requested set.
        let anyRunning = requestedIDs.contains { cameraCaptures[$0] != nil }
        if !failures.isEmpty && !anyRunning {
            throw RecorderError.allCameraSourcesFailed
        }
    }

    private func effectiveCameraIdentifiers() -> [String] {
        if !cameraSourceIdentifiers.isEmpty {
            return Array(cameraSourceIdentifiers.prefix(MultiCameraLayout.maxSupportedSources))
        }

        if let fallback = CameraManager.defaultCameraIdentifier() {
            return [fallback]
        }

        return []
    }

    private func stopCameraCaptures() {
        for manager in cameraCaptures.values {
            manager.stopCapture()
        }
        cameraCaptures.removeAll()
        latestCameraBuffers.keys
            .filter { !remoteCameraIdentifiers.contains($0) }
            .forEach { latestCameraBuffers.removeValue(forKey: $0) }
        latestCameraMetadata.keys
            .filter { !remoteCameraIdentifiers.contains($0) }
            .forEach { latestCameraMetadata.removeValue(forKey: $0) }
    }

    /// Allows external components to provide metadata updates for a camera feed.
    public func updateCameraMetadata(_ event: CameraMetadataEvent) {
        latestCameraMetadata[event.sourceID] = event.metadata
        // print("🔔 [RecordingSession] Posting metadata notification for \(event.sourceID)")
        metadataHandler?(event)
    }

    /// Returns the last metadata value received for a particular camera.
    public func metadata(forCamera id: String) -> CameraMetadata? {
        latestCameraMetadata[id]
    }

    /// Listens for remote camera connections over TCP and advertises via Bonjour.
    /// Uses a dynamic port (0) by default to avoid conflicts. The actual port is advertised via Bonjour.
    public func enableRemoteCameraBridge(port: UInt16 = 0, serviceName: String? = nil) throws {
        if remoteCameraServer != nil {
            return
        }
        let server = RemoteCameraServer()
        server.delegate = self
        try server.start(port: port, serviceName: serviceName)
        remoteCameraServer = server
    }

    private func registerRemoteCamera(identifier: String) {
        if !remoteCameraIdentifiers.contains(identifier) {
            remoteCameraIdentifiers.insert(identifier)
        }
    }

    // Debug throttle for floating head logging

    private func dispatchPreview(for identifier: String, buffer: CMSampleBuffer) {
        guard let handler = previewHandler,
              let pixelBuffer = CMSampleBufferGetImageBuffer(buffer)
        else {
            return
        }

        var cgImage: CGImage?
        let isFloatingHead = compositor.floatingHeadEnabled

        // Apply person segmentation for floating head preview
        // Skip during recording to avoid running segmentation twice (compositor handles it)
        if isFloatingHead && !_isRecording {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            if let segmentedImage = compositor.applyFloatingHeadSegmentation(to: ciImage, pixelBuffer: pixelBuffer) {
                cgImage = previewCIContext.createCGImage(segmentedImage, from: segmentedImage.extent)
            }
        }

        // Fall back to direct conversion if segmentation didn't produce an image
        if cgImage == nil {
            let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
            guard status == noErr else { return }
        }

        if let cgImage {
            handler(CameraPreviewEvent(sourceID: identifier, image: cgImage))
        }
    }

    private func cameraLayersForComposition() -> [CompositorManager.CameraLayer] {
        guard enableCamera else { return [] }

        let orderedIdentifiers = cameraSourceIdentifiers.isEmpty
            ? Array(latestCameraBuffers.keys)
            : cameraSourceIdentifiers

        return orderedIdentifiers.enumerated().compactMap { index, identifier in
            guard let buffer = latestCameraBuffers[identifier] else { return nil }
            let placement = placementForCamera(at: index, total: max(orderedIdentifiers.count, 1))
            return CompositorManager.CameraLayer(id: identifier, buffer: buffer, position: placement)
        }
    }

    private func placementForCamera(at index: Int, total: Int) -> PiPPosition {
        if total <= 1 {
            return pipPosition
        }

        if case .grid = cameraLayoutStrategy {
            let ordered = [PiPPosition.topLeft, .topRight, .bottomLeft, .bottomRight]
            return ordered[index % ordered.count]
        }

        let ordered = [pipPosition] + PiPPosition.allCases.filter { $0 != pipPosition }
        return ordered[index % ordered.count]
    }
}

// MARK: - Remote Camera Delegate

@MainActor
extension RecordingSession: RemoteCameraServerDelegate {
    public func remoteCameraServer(_: RemoteCameraServer, didReceiveFrame buffer: CMSampleBuffer, sourceID: String) {
        registerRemoteCamera(identifier: sourceID)
        latestCameraBuffers[sourceID] = buffer
        dispatchPreview(for: sourceID, buffer: buffer)
    }

    public func remoteCameraServer(_: RemoteCameraServer, didReceive metadata: CameraMetadataEvent) {
        // print("📥 [RecordingSession] Received metadata from remote camera: \(metadata.sourceID)")
        registerRemoteCamera(identifier: metadata.sourceID)
        updateCameraMetadata(metadata)
        // print("   └─ Metadata forwarded to handler")
    }

    public func remoteCameraServer(_: RemoteCameraServer, didUpdateSources sources: [String]) {
        remoteCameraIdentifiers = Set(sources)

        // Remove stale buffers/metadata for disconnected sources
        let activeRemoteSources = remoteCameraIdentifiers
        latestCameraBuffers.keys
            .filter { !activeRemoteSources.contains($0) && cameraCaptures[$0] == nil }
            .forEach { latestCameraBuffers.removeValue(forKey: $0) }

        latestCameraMetadata.keys
            .filter { !activeRemoteSources.contains($0) && cameraCaptures[$0] == nil }
            .forEach { latestCameraMetadata.removeValue(forKey: $0) }

        remoteSourcesHandler?(Array(remoteCameraIdentifiers).sorted())
    }
}
#endif

public enum MultiCameraLayout: String, CaseIterable, Identifiable, Sendable {
    case pictureInPicture = "Picture in Picture"
    case grid = "Grid"

    public var id: String { rawValue }

    public static let maxSupportedSources = 4
}

public struct CameraPreviewEvent: Sendable {
    public let sourceID: String
    public let image: CGImage

    public init(sourceID: String, image: CGImage) {
        self.sourceID = sourceID
        self.image = image
    }
}

/// Describes a camera source that could not be started.
public struct CameraStartFailure: Sendable {
    /// The camera identifier that was requested (an `AVCaptureDevice.uniqueID`).
    public let sourceID: String
    /// The underlying error thrown by `CameraManager.startCapture(with:)`.
    public let error: any Error
    /// A short, user-facing explanation derived from `error`.
    public let message: String

    public init(sourceID: String, error: any Error) {
        self.sourceID = sourceID
        self.error = error
        self.message = Self.message(for: error)
    }

    /// Maps a camera start error to a user-facing message. Distinguishes not authorized,
    /// device unavailable/not found, in use / cannot add input; everything else falls back
    /// to the error's own description.
    public static func message(for error: any Error) -> String {
        if let recorderError = error as? RecorderError {
            switch recorderError {
            case .permissionDenied:
                return notAuthorizedMessage
            case .cameraUnavailable:
                return unavailableMessage
            case .cannotAddInput:
                return inUseMessage
            default:
                break
            }
        }

        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain {
            switch AVError.Code(rawValue: nsError.code) {
            case .applicationIsNotAuthorizedToUseDevice:
                return notAuthorizedMessage
            case .deviceNotConnected:
                return unavailableMessage
            case .deviceInUseByAnotherApplication, .deviceAlreadyUsedByAnotherSession:
                return inUseMessage
            default:
                break
            }
        }

        return "Camera could not be started: \(error.localizedDescription)"
    }

    private static let notAuthorizedMessage = "Camera access is not authorized. Allow camera access in System Settings > Privacy & Security > Camera."
    private static let unavailableMessage = "Camera is unavailable. It may be disconnected or no longer present."
    private static let inUseMessage = "Camera is in use by another app or could not be added to the capture session."
}
