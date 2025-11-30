import CoreGraphics
import Foundation

#if os(macOS)
@preconcurrency import AVFoundation
import ArkavoStreaming
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
    nonisolated(unsafe) private let compositor: CompositorManager
    nonisolated(unsafe) private let encoder: VideoEncoder

    // Recording state tracked locally for synchronous access
    // This is updated when recording starts/stops
    nonisolated(unsafe) private var _isRecording: Bool = false
    nonisolated(unsafe) private var recordingStartTime: Date?

    nonisolated public var isRecording: Bool {
        _isRecording
    }

    public var duration: TimeInterval {
        guard _isRecording, let startTime = recordingStartTime else { return 0 }
        return Date().timeIntervalSince(startTime)
    }

    nonisolated(unsafe) public var audioLevel: Float = 0.0

    // Configuration
    public var pipPosition: PiPPosition {
        get { compositor.pipPosition }
        set { compositor.pipPosition = newValue }
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

    /// Timer for driving frame capture in non-desktop modes
    nonisolated(unsafe) private var cameraFrameTimer: Timer?

    /// Debug logging throttle
    nonisolated(unsafe) private var lastDebugLogTime: Date?

    /// Standard canvas size for camera/avatar-only modes (1080p)
    private let standardCanvasSize = CGSize(width: 1920, height: 1080)

    public var cameraSourceIdentifiers: [String] = []
    public var cameraLayoutStrategy: MultiCameraLayout = .pictureInPicture
    public var metadataHandler: (@Sendable (CameraMetadataEvent) -> Void)?
    public var previewHandler: (@Sendable (CameraPreviewEvent) -> Void)?
    nonisolated(unsafe) public var screenPreviewHandler: (@Sendable (CGImage) -> Void)?
    public var remoteSourcesHandler: (@Sendable ([String]) -> Void)?
    /// Handler for monitor frames - receives the final composed frame before encoding
    nonisolated(unsafe) public var monitorFrameHandler: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
    nonisolated(unsafe) private var isScreenPreviewOnly: Bool = false

    // MARK: - Initialization

    public init() throws {
        self.screenCapture = ScreenCaptureManager()
        self.cameraCaptures = [:]
        self.audioRouter = AudioRouter()
        self.compositor = try CompositorManager()
        self.encoder = VideoEncoder()

        setupCapture()
    }

    // MARK: - Setup

    private nonisolated func setupCapture() {
        // Wire up screen capture
        screenCapture.onFrame = { @Sendable [weak self] screenBuffer in
            // Process asynchronously to handle encoding
            // Note: CMSampleBuffer is not Sendable, but we process it immediately without retaining
            Task {
                await self?.processScreenFrame(screenBuffer)
            }
        }

        // Wire up audio router
        audioRouter.onConvertedSample = { @Sendable [weak self] audioSample, sourceID in
            // Process asynchronously to handle encoding
            // Note: CMSampleBuffer is not Sendable, but we process it immediately without retaining
            Task {
                await self?.processAudioSampleSync(audioSample, sourceID: sourceID)
            }
        }
    }

    // MARK: - Recording Control

    /// Starts a new recording session
    public func startRecording(outputURL: URL, title: String) async throws {
        let mode = inputMode

        // Validate at least one input is enabled
        guard enableDesktop || enableCamera || enableAvatar || enableMicrophone else {
            throw RecorderError.permissionDenied // No inputs enabled
        }

        // Request permissions based on mode
        guard await requestPermissions() else {
            throw RecorderError.permissionDenied
        }

        // Clear preview-only mode so frames go to encoder
        isScreenPreviewOnly = false

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

        // STEP 2: Add microphone to audio router (but don't start yet)
        if mode.needsMicrophone {
            print("🎙️ RecordingSession: Adding microphone to audio router")
            let micSource = await audioRouter.addMicrophone()
            print("🎙️ RecordingSession: Microphone source created: \(micSource.sourceID)")
        }

        // STEP 3: Start encoder FIRST with pre-created audio tracks for all sources
        let audioSourceIDs = audioRouter.allSourceIDs
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
        recordingStartTime = Date()

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

    /// Stops the current recording session
    public func stopRecording() async throws -> URL {
        // Stop frame driver if running
        stopCameraFrameDriver()

        // Stop captures
        screenCapture.stopCapture()
        stopCameraCaptures()

        // Stop all audio sources
        try? await audioRouter.stopAll()

        // Finish encoding
        let result = try await encoder.finishRecording()

        // Update local recording state
        _isRecording = false
        recordingStartTime = nil

        print("🛑 [RecordingSession] Recording stopped")

        return result
    }

    /// Pauses the current recording
    public func pauseRecording() {
        Task {
            await encoder.pause()
        }
    }

    /// Resumes a paused recording
    public func resumeRecording() {
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
            guard await MicrophoneAudioSource.requestPermission() else {
                return false
            }
        }

        return true
    }

    nonisolated(unsafe) private var latestCameraBuffers: [String: CMSampleBuffer] = [:]

    private nonisolated func processScreenFrame(_ screenBuffer: CMSampleBuffer) async {
        // Dispatch screen preview if handler is set
        if let handler = screenPreviewHandler,
           let pixelBuffer = CMSampleBufferGetImageBuffer(screenBuffer) {
            var cgImage: CGImage?
            let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
            if status == noErr, let cgImage {
                handler(cgImage)
            }
        }

        // If preview-only mode, don't process for recording
        guard !isScreenPreviewOnly else { return }

        // Continue with recording if active
        await processFrameSync(screen: screenBuffer)
    }

    private nonisolated func processFrameSync(screen screenBuffer: CMSampleBuffer) async {
        guard _isRecording else { return }

        let mode = await MainActor.run { self.inputMode }

        // Desktop modes use screen as base
        guard mode.needsDesktop else { return }

        // Capture state on MainActor to ensure thread safety
        let (cameraLayers, isAvatarEnabled, provider, isCameraEnabled) = await MainActor.run {
            (
                self.cameraLayersForComposition(),
                self.enableAvatar,
                self.avatarTextureProvider,
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

        // Log once per second to avoid spam
        let now = Date()
        if lastDebugLogTime == nil || now.timeIntervalSince(lastDebugLogTime!) >= 1.0 {
            lastDebugLogTime = now
            let avatarSize = avatarTexture.map { "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))" } ?? "nil"
            print("🎥 [Composition] camera=\(isCameraEnabled), layers=\(cameraLayers.count), avatar=\(isAvatarEnabled), avatarTex=\(avatarSize)")
        }

        guard let composited = compositor.composite(
            screen: screenBuffer,
            cameraLayers: cameraLayers,
            avatarTexture: avatarTexture
        ) else {
            return
        }

        // Encode the composited frame
        let timestamp = CMSampleBufferGetPresentationTimeStamp(screenBuffer)

        // Send to monitor if handler is set
        monitorFrameHandler?(composited, timestamp)

        await encoder.encodeVideoFrame(composited, timestamp: timestamp)
    }

    /// Processes a frame for camera-only or avatar-only modes (called by timer)
    private nonisolated func processCameraOrAvatarFrame() async {
        guard _isRecording else { return }

        let mode = await MainActor.run { self.inputMode }
        let canvasSize = standardCanvasSize

        var composited: CVPixelBuffer?
        var timestamp: CMTime

        switch mode {
        case .cameraWithMic, .cameraOnly:
            // Camera-only modes: use first camera as primary, others as PiP
            let cameraLayers = await MainActor.run { self.cameraLayersForComposition() }
            guard !cameraLayers.isEmpty,
                  let firstBuffer = cameraLayers.first?.buffer
            else { return }

            composited = compositor.composite(
                cameraLayers: cameraLayers,
                canvasSize: canvasSize
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
                cameraLayers: cameraLayers
            )
            timestamp = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)

        default:
            // Desktop modes are handled by processFrameSync, audio-only has no video
            return
        }

        guard let output = composited else { return }

        // Send to monitor if handler is set
        monitorFrameHandler?(output, timestamp)

        await encoder.encodeVideoFrame(output, timestamp: timestamp)
    }

    // MARK: - Camera/Avatar Frame Driver

    /// Starts a timer to drive frame capture at 30fps for non-desktop modes
    private func startCameraFrameDriver() {
        stopCameraFrameDriver()

        cameraFrameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.processCameraOrAvatarFrame()
            }
        }
    }

    /// Stops the camera/avatar frame driver
    private func stopCameraFrameDriver() {
        cameraFrameTimer?.invalidate()
        cameraFrameTimer = nil
    }

    private nonisolated func processAudioSampleSync(_ audioSample: CMSampleBuffer, sourceID: String) async {
        guard _isRecording else {
            print("⚠️ RecordingSession: Audio sample from [\(sourceID)] dropped - not recording")
            return
        }

        // Encode audio with source ID for multi-track support
        await encoder.encodeAudioSample(audioSample, sourceID: sourceID)
    }

    // MARK: - Public Utilities

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

    /// Enable screen audio capture (macOS only)
    public var enableScreenAudio: Bool = false {
        didSet {
            if enableScreenAudio && !oldValue {
                Task { @MainActor in
                    let _ = await audioRouter.addScreenAudio()
                }
            }
        }
    }

    /// Get audio router for advanced audio source management
    public var audioSourceRouter: AudioRouter {
        audioRouter
    }

    /// Get camera preview session (first active camera if available)
    public func getCameraPreview() -> AVCaptureSession? {
        return cameraCaptures.values.first?.getPreviewSession()
    }

    /// Starts camera capture purely for preview purposes (no recording).
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
        isScreenPreviewOnly = true
        try screenCapture.startCapture(displayID: selectedDisplayID)
    }

    /// Stops screen preview capture.
    public func stopScreenPreview() {
        isScreenPreviewOnly = false
        screenCapture.stopCapture()
    }

    // MARK: - Streaming

    /// Start streaming to RTMP destination
    public func startStreaming(to destination: RTMPPublisher.Destination, streamKey: String) async throws {
        try await encoder.startStreaming(to: destination, streamKey: streamKey)
    }

    /// Stop streaming
    public func stopStreaming() async {
        await encoder.stopStreaming()
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
            do {
                try manager.startCapture(with: identifier)
            } catch {
                print("⚠️ Failed to start camera \(identifier): \(error)")
            }
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
        print("🔔 [RecordingSession] Posting metadata notification for \(event.sourceID)")
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

    private func dispatchPreview(for identifier: String, buffer: CMSampleBuffer) {
        guard let handler = previewHandler,
              let pixelBuffer = CMSampleBufferGetImageBuffer(buffer)
        else {
            return
        }

        var cgImage: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)

        if status == noErr, let cgImage {
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
        print("📥 [RecordingSession] Received metadata from remote camera: \(metadata.sourceID)")
        registerRemoteCamera(identifier: metadata.sourceID)
        updateCameraMetadata(metadata)
        print("   └─ Metadata forwarded to handler")
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
