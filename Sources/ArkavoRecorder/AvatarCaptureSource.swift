import CoreVideo
import Foundation

/// Helper to wait for avatar texture to become available
public enum AvatarCaptureHelper {
    /// Wait for the avatar texture provider to return a non-nil frame
    /// - Parameters:
    ///   - provider: The texture provider closure
    ///   - timeout: Maximum time to wait for first frame
    /// - Throws: CaptureSourceError.timeout if no frame within timeout
    public static func waitForFirstFrame(
        provider: @escaping @Sendable () -> CVPixelBuffer?,
        timeout: TimeInterval = 5.0
    ) async throws {
        let startTime = Date()
        let pollInterval: UInt64 = 16_000_000 // 16ms in nanoseconds (~60fps)

        print("🎭 [AvatarCaptureHelper] Waiting for first avatar frame...")

        // Check immediately
        if provider() != nil {
            print("🎭 [AvatarCaptureHelper] First frame already available")
            return
        }

        // Poll until we get a frame or timeout
        while true {
            if Date().timeIntervalSince(startTime) > timeout {
                throw CaptureSourceError.timeout(sourceID: "avatar", after: timeout)
            }

            try await Task.sleep(nanoseconds: pollInterval)

            if provider() != nil {
                let elapsed = Date().timeIntervalSince(startTime)
                print("🎭 [AvatarCaptureHelper] First frame ready after \(String(format: "%.2f", elapsed))s")
                return
            }
        }
    }
}
