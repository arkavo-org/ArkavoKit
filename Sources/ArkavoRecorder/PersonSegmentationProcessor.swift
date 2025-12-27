import CoreImage
import CoreVideo
import Vision

/// Processes camera frames to generate person segmentation masks for background removal
public final class PersonSegmentationProcessor: Sendable {
    nonisolated(unsafe) private var segmentationRequest: VNGeneratePersonSegmentationRequest?
    nonisolated(unsafe) private var sequenceHandler: VNSequenceRequestHandler?

    /// Whether person segmentation is enabled
    nonisolated(unsafe) public var isEnabled: Bool = false

    public init() {
        // Vision objects created lazily on first use
    }

    /// Ensures Vision objects are initialized
    private nonisolated func ensureInitialized() {
        if segmentationRequest == nil {
            let request = VNGeneratePersonSegmentationRequest()
            // Use .fast for real-time performance (preview uses this path)
            request.qualityLevel = .fast
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            segmentationRequest = request
            sequenceHandler = VNSequenceRequestHandler()
        }
    }

    // Debug throttle
    nonisolated(unsafe) private static var lastLogTime: Date?

    /// Process a frame and return the person segmentation mask
    /// - Parameter pixelBuffer: The camera frame to process
    /// - Returns: A grayscale mask CIImage where white is person, black is background
    public nonisolated func processFrame(_ pixelBuffer: CVPixelBuffer) -> CIImage? {
        guard isEnabled else { return nil }

        ensureInitialized()

        guard let request = segmentationRequest, let handler = sequenceHandler else {
            return nil
        }

        do {
            try handler.perform([request], on: pixelBuffer)
        } catch {
            // Debug logging (throttled)
            let now = Date()
            if Self.lastLogTime == nil || now.timeIntervalSince(Self.lastLogTime!) >= 1.0 {
                Self.lastLogTime = now
                print("🎭 [Segmentation] Error: \(error)")
            }
            return nil
        }

        guard let maskBuffer = request.results?.first?.pixelBuffer else {
            // Debug logging (throttled)
            let now = Date()
            if Self.lastLogTime == nil || now.timeIntervalSince(Self.lastLogTime!) >= 1.0 {
                Self.lastLogTime = now
                print("🎭 [Segmentation] No mask result")
            }
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
        // Scale mask to match image size
        let scaleX = image.extent.width / mask.extent.width
        let scaleY = image.extent.height / mask.extent.height
        let scaledMask = mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Apply mask: original image where mask is white, transparent where mask is black
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent),
            kCIInputMaskImageKey: scaledMask,
        ])
    }
}
