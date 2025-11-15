import CoreGraphics
import Foundation

#if os(macOS)
@preconcurrency import AVFoundation
import ArkavoStreaming
import VideoToolbox

/// Coordinates screen, camera, and audio capture with composition and encoding
@MainActor
public final class RecordingSession: Sendable {
    // MARK: - Properties

    private let screenCapture: ScreenCaptureManager
    private var cameraCaptures: [String: CameraManager]
    private var latestCameraMetadata: [String: CameraMetadata] = [:]
    private var remoteCameraIdentifiers: Set<String> = []
    public private(set) var remoteCameraServer: RemoteCameraServer?
    nonisolated(unsafe) private let audioRouter: AudioRouter
    nonisolated(unsafe) private let compositor: CompositorManager
    nonisolated(unsafe) private let encoder: VideoEncoder

    nonisolated(unsafe) public var isRecording: Bool {
        encoder.isRecording
    }

    public var duration: TimeInterval {
        encoder.duration
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
    public var cameraSourceIdentifiers: [String] = []
public var cameraLayoutStrategy: MultiCameraLayout = .pictureInPicture
public var metadataHandler: (@Sendable (CameraMetadataEvent) -> Void)?
    public var previewHandler: (@Sendable (CameraPreviewEvent) -> Void)?
    public var remoteSourcesHandler: (@Sendable ([String]) -> Void)?

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
                await self?.processFrameSync(screen: screenBuffer)
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
        // Request permissions
        guard await requestPermissions() else {
            throw RecorderError.permissionDenied
        }

        // Start captures
        try screenCapture.startCapture()

        if enableCamera {
            try startCameraCapturesIfNeeded()
        }

        if enableMicrophone {
            // Add microphone to audio router (but don't start it yet)
            print("🎙️ RecordingSession: Adding microphone to audio router")
            let micSource = await audioRouter.addMicrophone()
            print("🎙️ RecordingSession: Microphone source created: \(micSource.sourceID)")
        }

        // Start encoder FIRST with pre-created audio tracks for all sources
        let audioSourceIDs = audioRouter.allSourceIDs
        print("🎙️ RecordingSession: Creating encoder with audio tracks for: \(audioSourceIDs)")
        try await encoder.startRecording(to: outputURL, title: title, audioSourceIDs: audioSourceIDs)
        print("🎙️ RecordingSession: Encoder started and ready")

        // NOW start audio sources (after encoder is ready to receive samples)
        print("🎙️ RecordingSession: Starting all audio sources...")
        try? await audioRouter.startAll()
        print("🎙️ RecordingSession: Audio sources started. Active sources: \(audioRouter.activeSourceIDs)")
    }

    /// Stops the current recording session
    public func stopRecording() async throws -> URL {
        // Stop captures
        screenCapture.stopCapture()
        stopCameraCaptures()

        // Stop all audio sources
        try? await audioRouter.stopAll()

        // Finish encoding
        return try await encoder.finishRecording()
    }

    /// Pauses the current recording
    public func pauseRecording() {
        encoder.pause()
    }

    /// Resumes a paused recording
    public func resumeRecording() {
        encoder.resume()
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

    private nonisolated func processFrameSync(screen screenBuffer: CMSampleBuffer) async {
        guard encoder.isRecording else { return }

        let cameraLayers = await MainActor.run { self.cameraLayersForComposition() }
        guard let composited = compositor.composite(
            screen: screenBuffer,
            cameraLayers: cameraLayers
        ) else {
            return
        }

        // Encode the composited frame
        let timestamp = CMSampleBufferGetPresentationTimeStamp(screenBuffer)
        await encoder.encodeVideoFrame(composited, timestamp: timestamp)
    }

    private nonisolated func processAudioSampleSync(_ audioSample: CMSampleBuffer, sourceID: String) async {
        guard encoder.isRecording else {
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
        stopCameraCaptures()

        let identifiers = effectiveCameraIdentifiers()
        guard enableCamera, !identifiers.isEmpty else { return }

        for identifier in identifiers {
            if remoteCameraIdentifiers.contains(identifier) {
                // Remote feeds push frames asynchronously; no local capture session needed.
                continue
            }
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
