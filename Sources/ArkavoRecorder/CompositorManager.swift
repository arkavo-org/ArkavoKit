@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Metal
import MetalKit

/// Manages Metal-based composition of screen and camera frames for picture-in-picture
public final class CompositorManager: Sendable {
    // MARK: - Properties

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext

    public struct CameraLayer {
        public let id: String
        public let buffer: CMSampleBuffer
        public let position: PiPPosition?

        public init(id: String, buffer: CMSampleBuffer, position: PiPPosition?) {
            self.id = id
            self.buffer = buffer
            self.position = position
        }
    }

    // PiP configuration
    public nonisolated(unsafe) var pipPosition: PiPPosition = .bottomRight
    public nonisolated(unsafe) var pipScale: Float = 0.2 // 20% of screen size

    // Watermark configuration
    public nonisolated(unsafe) var watermarkEnabled: Bool = true // Enabled by default per MVP spec
    public nonisolated(unsafe) var watermarkPosition: WatermarkPosition = .bottomCenter
    public nonisolated(unsafe) var watermarkOpacity: Float = 0.6 // 60% opacity

    // Cached watermark image
    private nonisolated(unsafe) var watermarkImage: CIImage?

    // MARK: - Initialization

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RecorderError.encodingFailed
        }

        guard let commandQueue = device.makeCommandQueue() else {
            throw RecorderError.encodingFailed
        }

        self.device = device
        self.commandQueue = commandQueue
        ciContext = CIContext(mtlDevice: device)

        // Generate watermark image
        watermarkImage = createWatermarkImage()
    }

    // MARK: - Public Methods

    /// Composites screen and camera frames into a single frame with PiP layout
    public func composite(
        screen screenBuffer: CMSampleBuffer,
        cameraLayers: [CameraLayer]
    ) -> CVPixelBuffer? {
        // Get screen image buffer
        guard let screenPixelBuffer = CMSampleBufferGetImageBuffer(screenBuffer) else {
            return nil
        }

        let screenImage = CIImage(cvPixelBuffer: screenPixelBuffer)
        let screenSize = screenImage.extent.size
        var composited = screenImage

        for (index, layer) in cameraLayers.enumerated() {
            guard let cameraPixelBuffer = CMSampleBufferGetImageBuffer(layer.buffer) else {
                continue
            }

            let cameraImage = CIImage(cvPixelBuffer: cameraPixelBuffer)

            // Calculate PiP dimensions and position
            let pipSize = pipSize(for: screenSize, cameraCount: cameraLayers.count)

            // Scale camera to PiP size maintaining aspect ratio
            let cameraAspect = cameraImage.extent.width / cameraImage.extent.height
            let pipAspect = pipSize.width / pipSize.height

            var scaledCameraSize = pipSize
            if cameraAspect > pipAspect {
                scaledCameraSize.height = pipSize.width / cameraAspect
            } else {
                scaledCameraSize.width = pipSize.height * cameraAspect
            }

            let scaleX = scaledCameraSize.width / cameraImage.extent.width
            let scaleY = scaledCameraSize.height / cameraImage.extent.height
            let scaledCamera = cameraImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

            // Calculate position based on PiP setting or provided override
            let placement = layer.position ?? pipPosition
            let position: CGPoint
            if cameraLayers.count > 1 {
                position = multiCameraPosition(
                    screenSize: screenSize,
                    pipSize: scaledCameraSize,
                    preferred: placement,
                    index: index
                )
            } else {
                position = calculatePiPPosition(
                    screenSize: screenSize,
                    pipSize: scaledCameraSize,
                    position: placement
                )
            }

            // Position the camera overlay
            let positionedCamera = scaledCamera.transformed(by: CGAffineTransform(translationX: position.x, y: position.y))

            // Add rounded corners and border to PiP
            let pipWithEffects = addPiPEffects(to: positionedCamera, size: scaledCameraSize)

            // Composite the images
            composited = pipWithEffects.composited(over: composited)
        }

        // Add watermark if enabled
        if watermarkEnabled {
            composited = addWatermark(to: composited, screenSize: screenSize)
        }

        // Render to pixel buffer
        return renderToPixelBuffer(image: composited, size: screenSize)
    }

    // MARK: - Private Methods

    private func calculatePiPPosition(
        screenSize: CGSize,
        pipSize: CGSize,
        position: PiPPosition
    ) -> CGPoint {
        let margin: CGFloat = 20
        switch position {
        case .topLeft:
            return CGPoint(x: margin, y: screenSize.height - pipSize.height - margin)
        case .topRight:
            return CGPoint(x: screenSize.width - pipSize.width - margin, y: screenSize.height - pipSize.height - margin)
        case .bottomLeft:
            return CGPoint(x: margin, y: margin)
        case .bottomRight:
            return CGPoint(x: screenSize.width - pipSize.width - margin, y: margin)
        }
    }

    private func addPiPEffects(to image: CIImage, size: CGSize) -> CIImage {
        // Add rounded corners
        let cornerRadius: CGFloat = 12

        // Create rounded rectangle mask
        let maskRect = CGRect(origin: .zero, size: size)
        let mask = CIImage(color: CIColor.white)
            .cropped(to: maskRect)
            .applyingFilter("CIBoxBlur", parameters: ["inputRadius": cornerRadius])

        // Apply mask
        let maskedImage = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: CIColor.clear).cropped(to: image.extent),
            kCIInputMaskImageKey: mask,
        ])

        // Add subtle border/shadow
        // This is a simplified version - could be enhanced with CIFilter effects
        return maskedImage
    }

    private func renderToPixelBuffer(image: CIImage, size: CGSize) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?

        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer,
        )

        guard status == kCVReturnSuccess, let outputBuffer = pixelBuffer else {
            return nil
        }

        ciContext.render(image, to: outputBuffer)
        return outputBuffer
    }

    // MARK: - Watermark Methods

    /// Creates the watermark image with "Recorded with Arkavo Creator" text
    private func createWatermarkImage() -> CIImage? {
        #if os(macOS)
            // Create attributed string for watermark text
            let text = "Recorded with Arkavo Creator"
            let fontSize: CGFloat = 24
            let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white,
                .shadow: {
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
                    shadow.shadowBlurRadius = 4
                    shadow.shadowOffset = CGSize(width: 0, height: -2)
                    return shadow
                }(),
            ]

            let attributedString = NSAttributedString(string: text, attributes: attributes)

            // Calculate text size
            let textSize = attributedString.size()
            let padding: CGFloat = 16

            // Create image with padding
            let imageSize = CGSize(
                width: textSize.width + padding * 2,
                height: textSize.height + padding * 2,
            )

            // Draw text to image
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(imageSize.width),
                pixelsHigh: Int(imageSize.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0,
            ) else {
                return nil
            }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

            // Draw text centered
            let textRect = CGRect(
                x: padding,
                y: padding,
                width: textSize.width,
                height: textSize.height,
            )
            attributedString.draw(in: textRect)

            NSGraphicsContext.restoreGraphicsState()

            // Convert to CIImage
            guard let cgImage = rep.cgImage else {
                return nil
            }

            return CIImage(cgImage: cgImage)
        #else
            return nil
        #endif
    }

    /// Adds watermark to the composited image
    private func addWatermark(to image: CIImage, screenSize: CGSize) -> CIImage {
        guard let watermark = watermarkImage else {
            return image
        }

        // Calculate watermark position
        let position = calculateWatermarkPosition(
            screenSize: screenSize,
            watermarkSize: watermark.extent.size,
            position: watermarkPosition,
        )

        // Position watermark
        let positionedWatermark = watermark.transformed(
            by: CGAffineTransform(translationX: position.x, y: position.y),
        )

        // Apply opacity
        let transparentWatermark = positionedWatermark.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(watermarkOpacity)),
        ])

        // Composite watermark over image
        return transparentWatermark.composited(over: image)
    }

    /// Calculates watermark position based on settings
    private func calculateWatermarkPosition(
        screenSize: CGSize,
        watermarkSize: CGSize,
        position: WatermarkPosition,
    ) -> CGPoint {
        let margin: CGFloat = 30

        switch position {
        case .topLeft:
            return CGPoint(
                x: margin,
                y: screenSize.height - watermarkSize.height - margin,
            )
        case .topRight:
            return CGPoint(
                x: screenSize.width - watermarkSize.width - margin,
                y: screenSize.height - watermarkSize.height - margin,
            )
        case .bottomLeft:
            return CGPoint(
                x: margin,
                y: margin,
            )
        case .bottomRight:
            return CGPoint(
                x: screenSize.width - watermarkSize.width - margin,
                y: margin,
            )
        case .bottomCenter:
            return CGPoint(
                x: (screenSize.width - watermarkSize.width) / 2,
                y: margin,
            )
        }
    }

    private func multiCameraPosition(
        screenSize: CGSize,
        pipSize: CGSize,
        preferred: PiPPosition,
        index: Int
    ) -> CGPoint {
        let orderedPositions: [PiPPosition] = {
            var order = [preferred]
            order.append(contentsOf: PiPPosition.allCases.filter { $0 != preferred })
            return order
        }()
        let resolved = orderedPositions[index % orderedPositions.count]
        return calculatePiPPosition(screenSize: screenSize, pipSize: pipSize, position: resolved)
    }

    private func pipSize(for screenSize: CGSize, cameraCount: Int) -> CGSize {
        let multiplier: CGFloat
        switch cameraCount {
        case 0, 1:
            multiplier = CGFloat(pipScale)
        case 2:
            multiplier = CGFloat(pipScale * 0.9)
        case 3:
            multiplier = CGFloat(pipScale * 0.8)
        default:
            multiplier = CGFloat(pipScale * 0.7)
        }

        return CGSize(
            width: screenSize.width * multiplier,
            height: screenSize.height * multiplier
        )
    }
}

public enum PiPPosition: String, Sendable, CaseIterable, Identifiable {
    case topLeft = "Top Left"
    case topRight = "Top Right"
    case bottomLeft = "Bottom Left"
    case bottomRight = "Bottom Right"

    public var id: String { rawValue }
}

public enum WatermarkPosition: String, Sendable, CaseIterable, Identifiable {
    case topLeft = "Top Left"
    case topRight = "Top Right"
    case bottomLeft = "Bottom Left"
    case bottomRight = "Bottom Right"
    case bottomCenter = "Bottom Center"

    public var id: String { rawValue }
}
