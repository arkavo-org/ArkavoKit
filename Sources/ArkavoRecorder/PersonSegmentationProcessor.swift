import CoreImage
import CoreVideo
import os
import Vision

/// Processes camera frames to generate person segmentation masks for background removal
public final class PersonSegmentationProcessor: Sendable {
    private final class VisionState: @unchecked Sendable {
        var segmentationRequest: VNGeneratePersonSegmentationRequest?
        var sequenceHandler: VNSequenceRequestHandler?
    }

    private let enabledLock = OSAllocatedUnfairLock(initialState: false)
    private let visionLock = NSLock()
    private let visionState = VisionState()

    /// Whether person segmentation is enabled
    public var isEnabled: Bool {
        get { enabledLock.withLock { $0 } }
        set { enabledLock.withLock { $0 = newValue } }
    }

    public init() {
        // Vision objects created lazily on first use
    }

    /// Ensures Vision objects are initialized (caller must hold `visionLock`)
    private func ensureInitializedLocked() {
        if visionState.segmentationRequest == nil {
            let request = VNGeneratePersonSegmentationRequest()
            // Use .fast for real-time performance (preview uses this path)
            request.qualityLevel = .fast
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            visionState.segmentationRequest = request
            visionState.sequenceHandler = VNSequenceRequestHandler()
        }
    }

    // Debug throttle
    private static let lastLogTimeLock = OSAllocatedUnfairLock<Date?>(initialState: nil)

    private static func logThrottled(_ message: String) {
        let shouldLog = lastLogTimeLock.withLock { lastTime -> Bool in
            let now = Date()
            if let lastTime, now.timeIntervalSince(lastTime) < 1.0 {
                return false
            }
            lastTime = now
            return true
        }
        if shouldLog {
            print(message)
        }
    }

    /// Process a frame and return the person segmentation mask
    /// - Parameter pixelBuffer: The camera frame to process
    /// - Returns: A grayscale mask CIImage where white is person, black is background
    public nonisolated func processFrame(_ pixelBuffer: CVPixelBuffer) -> CIImage? {
        guard isEnabled else { return nil }

        visionLock.lock()
        defer { visionLock.unlock() }

        ensureInitializedLocked()

        guard let request = visionState.segmentationRequest,
              let handler = visionState.sequenceHandler
        else {
            return nil
        }

        do {
            try handler.perform([request], on: pixelBuffer)
        } catch {
            Self.logThrottled("🎭 [Segmentation] Error: \(error)")
            return nil
        }

        guard let maskBuffer = request.results?.first?.pixelBuffer else {
            Self.logThrottled("🎭 [Segmentation] No mask result")
            return nil
        }

        return CIImage(cvPixelBuffer: maskBuffer)
    }

    /// Apply a segmentation mask to an image, making the background transparent
    /// - Parameters:
    ///   - image: The original camera image
    ///   - mask: The segmentation mask (person = white, background = black)
    /// - Returns: The image with transparent background where the mask is black
    public nonisolated func applyMask(to image: CIImage, mask: CIImage) -> CIImage {
        let maskExtent = mask.extent
        let imageExtent = image.extent

        guard maskExtent.width > 0, maskExtent.height > 0,
              maskExtent.width.isFinite, maskExtent.height.isFinite,
              imageExtent.width > 0, imageExtent.height > 0,
              imageExtent.width.isFinite, imageExtent.height.isFinite
        else {
            return image
        }

        // Scale mask to match image size and align its origin with image.extent.origin
        let scaleX = imageExtent.width / maskExtent.width
        let scaleY = imageExtent.height / maskExtent.height
        let scaledMask = mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let alignedMask = scaledMask.transformed(by: CGAffineTransform(
            translationX: imageExtent.minX - scaledMask.extent.minX,
            y: imageExtent.minY - scaledMask.extent.minY
        ))

        // Apply mask: original image where mask is white, transparent where mask is black
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: imageExtent),
            kCIInputMaskImageKey: alignedMask,
        ])
    }
}
