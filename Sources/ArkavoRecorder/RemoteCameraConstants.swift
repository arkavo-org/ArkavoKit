import Foundation
import CoreMedia

/// Shared constants for remote camera functionality
public enum RemoteCameraConstants {
    // MARK: - Network Discovery

    /// Bonjour service type for remote camera discovery
    public static let serviceType = "_arkavo-remote._tcp."

    /// Default port for remote camera server
    public static let defaultPort: UInt16 = 5757

    /// Maximum receive buffer size (1 MB)
    public static let maxReceiveBufferSize = 1_048_576

    /// Largest newline-delimited message the server holds for a peer (4 MiB). A connection
    /// that sends more without a newline is closed. At the 3 Mbps default with a keyframe
    /// every 2 s, a keyframe is a few hundred KiB, about a third more as base64 in JSON.
    public static let maxMessageSize = 4 * 1_048_576

    /// Most peers the server accepts at once; further connections are refused
    public static let maxConnections = 8

    // MARK: - Timeouts & Intervals

    /// Discovery timeout in seconds (10 seconds)
    public static let discoveryTimeout: TimeInterval = 10.0

    /// Service resolution timeout in seconds (5 seconds)
    public static let serviceResolutionTimeout: TimeInterval = 5.0

    /// Discovery polling interval in nanoseconds (0.5 seconds)
    public static let discoveryPollingInterval: UInt64 = 500_000_000

    /// Auto mode switch delay in nanoseconds (0.5 seconds)
    public static let modeDetectionNoDetectionThreshold = 60

    /// Auto mode switch delay in nanoseconds (0.5 seconds)
    public static let modeDetectionFrameThreshold: Int = 60

    /// Logging interval for no detection (frames)
    public static let noDetectionLoggingInterval: Int = 30

    // MARK: - Video Encoding

    /// Target frame rate for remote camera streaming (30 FPS - full ARKit rate)
    public static let targetFrameRate: Double = 30.0

    /// Frame interval for streaming (1/30 seconds ≈ 33ms)
    public static let frameInterval: CFTimeInterval = 1.0 / targetFrameRate

    /// H.264 video bitrate (3 Mbps default)
    public static let h264Bitrate: Int = 3_000_000

    /// H.264 keyframe interval (I-frame every 2 seconds at 30 FPS)
    public static let h264KeyFrameInterval: Int = 60

    /// Video timescale for CMTime (600 units per second)
    public static let videoTimescale: CMTimeScale = 600
}
