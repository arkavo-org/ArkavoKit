@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Metal
import MetalKit
import os

/// Manages Metal-based composition of screen and camera frames for picture-in-picture
public final class CompositorManager: Sendable {
    // MARK: - Properties

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext

    private struct Settings: @unchecked Sendable {
        var outputSize: CGSize = CGSize(width: 1920, height: 1080)
        var pipPosition: PiPPosition = .bottomRight
        var pipScale: Float = 0.2
        var watermarkEnabled: Bool = true // Enabled by default per MVP spec
        var watermarkPosition: WatermarkPosition = .bottomCenter
        var watermarkOpacity: Float = 0.6 // 60% opacity
        var sceneOverlayText: String? = nil
        var sceneOverlayIcon: String? = nil  // SF Symbol name
        var sceneOverlayGradientColors: (start: CGColor, end: CGColor)? = nil
        var floatingHeadEnabled: Bool = false
    }

    private let settingsLock = OSAllocatedUnfairLock(initialState: Settings())

    /// Output resolution for the composited frames (must match encoder resolution)
    public var outputSize: CGSize {
        get { settingsLock.withLock { $0.outputSize } }
        set { settingsLock.withLock { $0.outputSize = newValue } }
    }

    /// A camera frame to composite. It's read on the main actor and composited off it.
    ///
    /// Unchecked because `CMSampleBuffer` isn't `Sendable`: CoreMedia lets a holder change a
    /// buffer's attachments. A layer's buffer is a delivered camera frame, which the compositor
    /// only reads and nothing else changes, and CoreFoundation retains and releases atomically.
    public struct CameraLayer: @unchecked Sendable {
        public let id: String
        public let buffer: CMSampleBuffer
        public let position: PiPPosition?

        public init(id: String, buffer: CMSampleBuffer, position: PiPPosition?) {
            self.id = id
            self.buffer = buffer
            self.position = position
        }
    }

    // Camera PiP configuration. Avatar and Muse are placed by their slots, not by these.

    /// The corner a camera PiP goes to when its layer names none.
    public var pipPosition: PiPPosition {
        get { settingsLock.withLock { $0.pipPosition } }
        set { settingsLock.withLock { $0.pipPosition = newValue } }
    }

    /// A camera PiP's size, as a fraction of the output size.
    public var pipScale: Float {
        get { settingsLock.withLock { $0.pipScale } }
        set { settingsLock.withLock { $0.pipScale = newValue } }
    }

    // Avatar and Muse slot layers

    /// Where the avatar and Muse slot layers go. Each value is written under one lock and a frame
    /// snapshots all four once, so a rect never tears mid-composite. Each setter writes one value,
    /// so a frame composed between two writes can pair a slot set this turn with the rect before it;
    /// `setLayerPlacement` writes all four at once.
    private struct LayerPlacement: Sendable {
        var avatarSlot = AvatarSlot(slot: CGRect(x: 0.71, y: 0.38, width: 0.28, height: 0.62), anchor: .bottomRight)
        var avatarVisibleRect = AvatarSlotLayout.fullTexture
        var museSlot = AvatarSlot(slot: CGRect(x: 0.01, y: 0.38, width: 0.28, height: 0.62), anchor: .bottomLeft)
        var museVisibleRect = AvatarSlotLayout.fullTexture
    }

    private let layerPlacement = OSAllocatedUnfairLock(initialState: LayerPlacement())

    /// The slot the avatar overlay fits into over a screen, normalized to the output with a top-left
    /// origin. Gameplay right by default. An avatar that is itself the base fills the output instead.
    public var avatarSlot: AvatarSlot {
        get { layerPlacement.withLock { $0.avatarSlot } }
        set { layerPlacement.withLock { $0.avatarSlot = newValue } }
    }

    /// The part of the avatar texture that holds the avatar, normalized with a top-left origin: the
    /// part fitted into `avatarSlot`. The whole texture by default.
    public var avatarVisibleRect: CGRect {
        get { layerPlacement.withLock { $0.avatarVisibleRect } }
        set { layerPlacement.withLock { $0.avatarVisibleRect = newValue } }
    }

    /// The slot the Muse layer fits into, over any base. Gameplay left by default.
    public var museSlot: AvatarSlot {
        get { layerPlacement.withLock { $0.museSlot } }
        set { layerPlacement.withLock { $0.museSlot = newValue } }
    }

    /// The part of the Muse texture fitted into `museSlot`. The whole texture by default.
    public var museVisibleRect: CGRect {
        get { layerPlacement.withLock { $0.museVisibleRect } }
        set { layerPlacement.withLock { $0.museVisibleRect = newValue } }
    }

    /// Swaps both slots and both visible rects in one step, so no frame pairs a new slot with an old rect.
    public func setLayerPlacement(
        avatarSlot: AvatarSlot, avatarVisibleRect: CGRect, museSlot: AvatarSlot, museVisibleRect: CGRect
    ) {
        let placement = LayerPlacement(
            avatarSlot: avatarSlot, avatarVisibleRect: avatarVisibleRect,
            museSlot: museSlot, museVisibleRect: museVisibleRect)
        layerPlacement.withLock { $0 = placement }
    }

    // Watermark configuration
    public var watermarkEnabled: Bool {
        get { settingsLock.withLock { $0.watermarkEnabled } }
        set { settingsLock.withLock { $0.watermarkEnabled = newValue } }
    }

    public var watermarkPosition: WatermarkPosition {
        get { settingsLock.withLock { $0.watermarkPosition } }
        set { settingsLock.withLock { $0.watermarkPosition = newValue } }
    }

    public var watermarkOpacity: Float {
        get { settingsLock.withLock { $0.watermarkOpacity } }
        set { settingsLock.withLock { $0.watermarkOpacity = newValue } }
    }

    // Scene overlay configuration (e.g. "Starting Soon...", "Be Right Back")
    public var sceneOverlayText: String? {
        get { settingsLock.withLock { $0.sceneOverlayText } }
        set { settingsLock.withLock { $0.sceneOverlayText = newValue } }
    }

    public var sceneOverlayIcon: String? {
        get { settingsLock.withLock { $0.sceneOverlayIcon } }
        set { settingsLock.withLock { $0.sceneOverlayIcon = newValue } }
    }

    public var sceneOverlayGradientColors: (start: CGColor, end: CGColor)? {
        get { settingsLock.withLockUnchecked { $0.sceneOverlayGradientColors } }
        set { settingsLock.withLockUnchecked { $0.sceneOverlayGradientColors = newValue } }
    }

    private struct SceneOverlayCache: @unchecked Sendable {
        var key: String?
        var image: CIImage?
    }

    private let sceneOverlayCacheLock = OSAllocatedUnfairLock(initialState: SceneOverlayCache())

    // Floating head (person segmentation) configuration
    public var floatingHeadEnabled: Bool {
        get { settingsLock.withLock { $0.floatingHeadEnabled } }
        set { settingsLock.withLock { $0.floatingHeadEnabled = newValue } }
    }

    /// Dedicated processor for preview segmentation
    private let previewSegmentationProcessor = PersonSegmentationProcessor()
    /// Per-camera processors so multi-camera compositing never shares one VNSequenceRequestHandler across cameras
    private let cameraSegmentationProcessors = OSAllocatedUnfairLock<[String: PersonSegmentationProcessor]>(initialState: [:])

    // Cached watermark image (immutable after init)
    private let watermarkImage: CIImage?

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
        watermarkImage = Self.createWatermarkImage()
    }

    // MARK: - Public Methods

    /// Composites screen and camera frames into a single frame with PiP layout
    public func composite(
        screen screenBuffer: CMSampleBuffer,
        cameraLayers: [CameraLayer],
        avatarTexture: CVPixelBuffer? = nil,
        museTexture: CVPixelBuffer? = nil
    ) -> sending CVPixelBuffer? {
        // Get screen image buffer
        guard let screenPixelBuffer = CMSampleBufferGetImageBuffer(screenBuffer) else {
            return nil
        }

        let screenImage = CIImage(cvPixelBuffer: screenPixelBuffer)
        let screenSize = screenImage.extent.size

        guard Self.isValidSize(screenSize) else {
            return nil
        }

        return compositeWithBase(
            baseImage: screenImage,
            baseSize: screenSize,
            cameraLayers: cameraLayers,
            avatarTexture: avatarTexture,
            museTexture: museTexture
        )
    }

    /// Composites camera frames without a screen base layer (camera-only mode)
    /// First camera becomes the primary full-canvas source, additional cameras become PiP overlays
    ///
    /// - Parameter canvasSize: The canvas the first camera fills and crops to. Give it the
    ///   output's shape (`outputSize` itself, as production does): the filled canvas is then
    ///   fitted into the output like any base, so a canvas of another shape gets bars.
    public func composite(
        cameraLayers: [CameraLayer],
        canvasSize: CGSize,
        museTexture: CVPixelBuffer? = nil
    ) -> sending CVPixelBuffer? {
        guard !cameraLayers.isEmpty, Self.isValidSize(canvasSize) else { return nil }

        // Use first camera as the base layer
        guard let firstLayer = cameraLayers.first,
              let firstPixelBuffer = CMSampleBufferGetImageBuffer(firstLayer.buffer)
        else {
            return nil
        }

        let firstCameraImage = CIImage(cvPixelBuffer: firstPixelBuffer)
        guard Self.isValidSize(firstCameraImage.extent.size) else { return nil }

        // Scale first camera to fill canvas (center crop to maintain aspect ratio)
        guard let scaledBaseImage = scaleToFillCanvas(image: firstCameraImage, canvasSize: canvasSize) else {
            return nil
        }

        // Remaining cameras become PiP overlays
        let overlayLayers = Array(cameraLayers.dropFirst())

        return compositeWithBase(baseImage: scaledBaseImage, baseSize: canvasSize, cameraLayers: overlayLayers, museTexture: museTexture)
    }

    /// Composites an avatar texture as the primary source with optional camera overlays
    public func composite(
        avatarTexture: CVPixelBuffer,
        cameraLayers: [CameraLayer] = [],
        museTexture: CVPixelBuffer? = nil
    ) -> sending CVPixelBuffer? {
        let avatarImage = CIImage(cvPixelBuffer: avatarTexture)
        let screenSize = avatarImage.extent.size
        guard Self.isValidSize(screenSize) else { return nil }

        return compositeWithBase(baseImage: avatarImage, baseSize: screenSize, cameraLayers: cameraLayers, museTexture: museTexture)
    }

    // MARK: - Private Composition Core

    /// Core composition logic: fits the base into the output, then overlays the avatar and Muse in
    /// their slots, the camera PiPs, the watermark and the scene overlay, all placed in output space.
    ///
    /// The base (`baseSize` is its size) is fitted inside the output and centred over black, so a
    /// base whose shape differs from the output gets bars rather than being stretched. Its scale is
    /// uniform, except that an axis within a pixel of the output is stretched to fill it, by under a
    /// pixel (`fittedBase`). Every overlay is sized and positioned against `outputSize`, independent
    /// of the base.
    private func compositeWithBase(
        baseImage: CIImage,
        baseSize: CGSize,
        cameraLayers: [CameraLayer],
        avatarTexture: CVPixelBuffer? = nil,
        museTexture: CVPixelBuffer? = nil
    ) -> sending CVPixelBuffer? {
        // Snapshot all mutable settings once so the whole frame sees one consistent state.
        let settings = settingsLock.withLock { $0 }
        let outputSize = settings.outputSize
        guard Self.isValidSize(outputSize), Self.isValidSize(baseSize) else {
            return nil
        }

        let outputRect = CGRect(origin: .zero, size: outputSize)

        var composited = fittedBase(baseImage, baseSize: baseSize, outputSize: outputSize)
            .composited(over: CIImage(color: .black).cropped(to: outputRect))

        // Read once: the whole frame uses one placement, even if the main actor changes it mid-frame.
        let placement = layerPlacement.withLock { $0 }

        if let avatarBuffer = avatarTexture {
            if let avatar = slotLayer(
                avatarBuffer, slot: placement.avatarSlot, visibleRect: placement.avatarVisibleRect,
                outputSize: outputSize) {
                composited = avatar.composited(over: composited)
            }
        }

        if let museBuffer = museTexture,
           let muse = slotLayer(
               museBuffer, slot: placement.museSlot, visibleRect: placement.museVisibleRect,
               outputSize: outputSize) {
            composited = muse.composited(over: composited)
        }

        if !settings.floatingHeadEnabled {
            cameraSegmentationProcessors.withLock { $0.removeAll() }
        } else {
            let activeIDs = Set(cameraLayers.map(\.id))
            cameraSegmentationProcessors.withLock { processors in
                for key in processors.keys where !activeIDs.contains(key) {
                    processors.removeValue(forKey: key)
                }
            }
        }

        for (index, layer) in cameraLayers.enumerated() {
            guard let cameraPixelBuffer = CMSampleBufferGetImageBuffer(layer.buffer) else {
                continue
            }

            var cameraImage = CIImage(cvPixelBuffer: cameraPixelBuffer)
            guard Self.isValidSize(cameraImage.extent.size) else {
                continue
            }

            // Apply person segmentation if floating head mode is enabled
            if settings.floatingHeadEnabled {
                let processor = segmentationProcessor(for: layer.id)
                processor.isEnabled = true
                if let mask = processor.processFrame(cameraPixelBuffer) {
                    cameraImage = processor.applyMask(to: cameraImage, mask: mask)
                }
            }

            // Calculate PiP dimensions and position
            let targetPiPSize = pipSize(for: outputSize, cameraCount: cameraLayers.count, pipScale: settings.pipScale)
            guard Self.isValidSize(targetPiPSize) else {
                continue
            }

            // Scale camera to PiP size maintaining aspect ratio
            let cameraAspect = cameraImage.extent.width / cameraImage.extent.height
            let pipAspect = targetPiPSize.width / targetPiPSize.height

            var scaledCameraSize = targetPiPSize
            if cameraAspect > pipAspect {
                scaledCameraSize.height = targetPiPSize.width / cameraAspect
            } else {
                scaledCameraSize.width = targetPiPSize.height * cameraAspect
            }

            guard Self.isValidSize(scaledCameraSize) else {
                continue
            }

            let scaleX = scaledCameraSize.width / cameraImage.extent.width
            let scaleY = scaledCameraSize.height / cameraImage.extent.height
            var scaledCamera = cameraImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            if scaledCamera.extent.origin != .zero {
                scaledCamera = scaledCamera.transformed(by: CGAffineTransform(
                    translationX: -scaledCamera.extent.minX,
                    y: -scaledCamera.extent.minY
                ))
            }

            // Use explicit corner directly when specified; only auto-distribute when layer.position == nil
            let position: CGPoint
            if let explicitPosition = layer.position {
                position = calculatePiPPosition(
                    screenSize: outputSize,
                    pipSize: scaledCameraSize,
                    position: explicitPosition
                )
            } else if cameraLayers.count > 1 {
                position = multiCameraPosition(
                    screenSize: outputSize,
                    pipSize: scaledCameraSize,
                    preferred: settings.pipPosition,
                    index: index
                )
            } else {
                position = calculatePiPPosition(
                    screenSize: outputSize,
                    pipSize: scaledCameraSize,
                    position: settings.pipPosition
                )
            }

            // Add rounded corners BEFORE positioning (mask needs to be at same origin as image)
            // Skip rounded corners when floating head is enabled (person shape is the border)
            let cameraWithEffects = settings.floatingHeadEnabled ? scaledCamera : addPiPEffects(to: scaledCamera, size: scaledCameraSize)

            // Position the camera overlay
            let positionedCamera = cameraWithEffects.transformed(by: CGAffineTransform(translationX: position.x, y: position.y))

            // Composite the images
            composited = positionedCamera.composited(over: composited)
        }

        // Add watermark if enabled
        if settings.watermarkEnabled {
            composited = addWatermark(
                to: composited,
                screenSize: outputSize,
                position: settings.watermarkPosition,
                opacity: settings.watermarkOpacity
            )
        }

        // Add scene overlay if active (Starting Soon, BRB, Ending)
        #if os(macOS)
        if let overlayText = settings.sceneOverlayText, !overlayText.isEmpty {
            composited = addSceneOverlay(
                to: composited,
                screenSize: outputSize,
                text: overlayText,
                icon: settings.sceneOverlayIcon,
                gradientColors: settings.sceneOverlayGradientColors
            )
        }
        #endif

        // Everything is already in output space; clip whatever overhangs the output.
        return renderToPixelBuffer(image: composited.cropped(to: outputRect), size: outputSize)
    }

    private func segmentationProcessor(for cameraID: String) -> PersonSegmentationProcessor {
        cameraSegmentationProcessors.withLock { processors in
            if let existing = processors[cameraID] {
                return existing
            }
            let created = PersonSegmentationProcessor()
            processors[cameraID] = created
            return created
        }
    }

    private static func isValidSize(_ size: CGSize) -> Bool {
        size.width > 0 && size.height > 0 && size.width.isFinite && size.height.isFinite
    }

    /// An avatar or Muse texture placed in its slot: the whole texture, drawn at the slot's
    /// `textureFrame` with one uniform scale, so its visible part lands on the fitted `visible` rect.
    /// The fit uses the texture's own size, so a texture of any shape lands inside its slot; every
    /// 16:9 size lands in the same place. It has no rounded PiP mask; only the output crop clips it.
    /// Nil when the texture or the slot is empty, so the frame goes on without that layer.
    private func slotLayer(
        _ buffer: CVPixelBuffer, slot: AvatarSlot, visibleRect: CGRect, outputSize: CGSize
    ) -> CIImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        guard Self.isValidSize(extent.size) else { return nil }
        let textureFrame = AvatarSlotLayout.frame(
            slot: slot, visibleRect: visibleRect, textureSize: extent.size, output: outputSize
        ).textureFrame
        guard Self.isValidSize(textureFrame.size) else { return nil }
        let target = AvatarSlotLayout.coreImageRect(textureFrame, outputHeight: outputSize.height)
        let scale = textureFrame.width / extent.width
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(by: CGAffineTransform(
            translationX: target.minX - scaled.extent.minX, y: target.minY - scaled.extent.minY))
    }

    /// Scales the base uniformly to fit inside the output and centres it, leaving bars on the
    /// unused axis. The base is not stretched, except that an axis within a pixel of the output
    /// fills it (`AvatarSlotLayout.aspectFit`), so no sub-pixel bar darkens the edge.
    private func fittedBase(_ base: CIImage, baseSize: CGSize, outputSize: CGSize) -> CIImage {
        guard Self.isValidSize(baseSize), Self.isValidSize(outputSize) else { return base }
        let fit = AvatarSlotLayout.coreImageRect(
            AvatarSlotLayout.aspectFit(baseSize, in: outputSize), outputHeight: outputSize.height)
        guard Self.isValidSize(fit.size) else { return base }
        let scaled = base.transformed(by: CGAffineTransform(
            scaleX: fit.width / baseSize.width, y: fit.height / baseSize.height))
        return scaled.transformed(by: CGAffineTransform(
            translationX: fit.minX - scaled.extent.minX, y: fit.minY - scaled.extent.minY))
    }

    /// Scales an image to fill the canvas size (center crop)
    private func scaleToFillCanvas(image: CIImage, canvasSize: CGSize) -> CIImage? {
        let extent = image.extent
        guard Self.isValidSize(extent.size), Self.isValidSize(canvasSize) else {
            return nil
        }

        let imageAspect = extent.width / extent.height
        let canvasAspect = canvasSize.width / canvasSize.height

        let scale: CGFloat
        if imageAspect > canvasAspect {
            // Image is wider - scale by height
            scale = canvasSize.height / extent.height
        } else {
            // Image is taller - scale by width
            scale = canvasSize.width / extent.width
        }

        let scaledImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Normalize origin to (0, 0) before cropping
        let normalized = scaledImage.transformed(by: CGAffineTransform(
            translationX: -scaledImage.extent.minX,
            y: -scaledImage.extent.minY
        ))

        // Center crop to canvas size
        let offsetX = (normalized.extent.width - canvasSize.width) / 2
        let offsetY = (normalized.extent.height - canvasSize.height) / 2
        let cropRect = CGRect(x: offsetX, y: offsetY, width: canvasSize.width, height: canvasSize.height)

        return normalized.cropped(to: cropRect).transformed(by: CGAffineTransform(translationX: -offsetX, y: -offsetY))
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

    /// Apply floating head segmentation to a camera image for preview
    /// - Parameters:
    ///   - image: The camera image as CIImage
    ///   - pixelBuffer: The original pixel buffer for Vision processing
    /// - Returns: The segmented image with transparent background, or nil if segmentation fails
    public nonisolated func applyFloatingHeadSegmentation(to image: CIImage, pixelBuffer: CVPixelBuffer) -> CIImage? {
        guard floatingHeadEnabled else { return nil }

        previewSegmentationProcessor.isEnabled = true
        guard let mask = previewSegmentationProcessor.processFrame(pixelBuffer) else {
            return nil
        }

        return previewSegmentationProcessor.applyMask(to: image, mask: mask)
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

    /// Renders into a new buffer the compositor keeps no reference to, so every composite's caller
    /// owns its frame and can send it on (to the encoder).
    private func renderToPixelBuffer(image: CIImage, size: CGSize) -> sending CVPixelBuffer? {
        guard Self.isValidSize(size) else { return nil }
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0 else { return nil }

        var pixelBuffer: CVPixelBuffer?

        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
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
    private static func createWatermarkImage() -> CIImage? {
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
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

            // Draw text centered
            let textRect = CGRect(
                x: padding,
                y: padding,
                width: textSize.width,
                height: textSize.height,
            )
            attributedString.draw(in: textRect)

            // Convert to CIImage
            guard let cgImage = rep.cgImage else {
                return nil
            }

            return CIImage(cgImage: cgImage)
        #else
            return nil
        #endif
    }

    /// Cache key for scene overlays, incorporating text, icon, gradient color components, and size.
    static func sceneOverlayCacheKey(
        text: String,
        icon: String?,
        gradientColors: (start: CGColor, end: CGColor)?,
        size: CGSize
    ) -> String {
        let gradientKey: String
        if let colors = gradientColors {
            gradientKey = "\(colorCacheKey(colors.start))->\(colorCacheKey(colors.end))"
        } else {
            gradientKey = "default"
        }
        return "\(text)|\(icon ?? "")|\(gradientKey)|\(Int(size.width))x\(Int(size.height))"
    }

    private static func colorCacheKey(_ color: CGColor) -> String {
        let spaceName = (color.colorSpace?.name as String?) ?? "unknown"
        let components = (color.components ?? []).map { String(format: "%.4f", $0) }.joined(separator: ",")
        return "\(spaceName):\(components):a=\(String(format: "%.4f", color.alpha))"
    }

    #if os(macOS)
    /// Renders a full-screen scene overlay (gradient background + icon + centered text)
    private func addSceneOverlay(
        to image: CIImage,
        screenSize: CGSize,
        text: String,
        icon iconName: String?,
        gradientColors: (start: CGColor, end: CGColor)?
    ) -> CIImage {
        let width = Int(screenSize.width)
        let height = Int(screenSize.height)
        guard width > 0, height > 0 else { return image }

        let cacheKey = Self.sceneOverlayCacheKey(
            text: text,
            icon: iconName,
            gradientColors: gradientColors,
            size: screenSize
        )

        let cachedImage: CIImage? = sceneOverlayCacheLock.withLockUnchecked { cache in
            guard cache.key == cacheKey, let cached = cache.image, cached.extent.size == screenSize else {
                return nil
            }
            return cached
        }
        if let cachedImage {
            return cachedImage.composited(over: image)
        }

        // Create bitmap context for the overlay
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return image
        }

        // Draw gradient background
        let startColor = gradientColors?.start ?? CGColor(red: 0.2, green: 0.2, blue: 0.6, alpha: 0.85)
        let endColor = gradientColors?.end ?? CGColor(red: 0.4, green: 0.1, blue: 0.5, alpha: 0.85)

        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [startColor, endColor] as CFArray,
            locations: [0.0, 1.0]
        ) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: CGFloat(height)),
                end: CGPoint(x: CGFloat(width), y: 0),
                options: []
            )
        }

        // Measure text
        let fontSize: CGFloat = CGFloat(height) / 14.0
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let attrString = NSAttributedString(string: text, attributes: textAttributes)
        let textSize = attrString.size()

        // Measure icon (thread-safe: extract CGImage without NSImage.lockFocus/unlockFocus)
        let iconSize: CGFloat = CGFloat(height) / 10.0
        let spacing: CGFloat = CGFloat(height) / 40.0
        var symbolCGImage: CGImage?
        var iconRect = CGRect.zero

        if let iconName {
            let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular)
            if let symbol = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                var proposedRect = NSRect(origin: .zero, size: symbol.size)
                if let cgSymbol = symbol.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
                    symbolCGImage = cgSymbol
                    iconRect.size = symbol.size
                }
            }
        }

        // Calculate total content height (icon + spacing + text)
        let totalHeight = iconRect.height + (symbolCGImage != nil ? spacing : 0) + textSize.height
        let centerY = (CGFloat(height) - totalHeight) / 2

        // Draw icon centered above text using pure CoreGraphics mask clipping (thread-safe)
        if let cgSymbol = symbolCGImage {
            let iconOrigin = CGPoint(
                x: (CGFloat(width) - iconRect.width) / 2,
                y: centerY + textSize.height + spacing
            )
            let drawRect = CGRect(origin: iconOrigin, size: iconRect.size)
            ctx.saveGState()
            ctx.clip(to: drawRect, mask: cgSymbol)
            ctx.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.9))
            ctx.fill(drawRect)
            ctx.restoreGState()
        }

        // Draw text centered below icon, properly saving and restoring NSGraphicsContext state
        ctx.saveGState()
        ctx.textMatrix = .identity
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        let textOrigin = CGPoint(
            x: (CGFloat(width) - textSize.width) / 2,
            y: centerY
        )
        attrString.draw(at: textOrigin)

        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        guard let cgImage = ctx.makeImage() else { return image }

        let overlayImage = CIImage(cgImage: cgImage)
        sceneOverlayCacheLock.withLockUnchecked { cache in
            cache.key = cacheKey
            cache.image = overlayImage
        }

        return overlayImage.composited(over: image)
    }
    #endif

    private func addWatermark(
        to image: CIImage,
        screenSize: CGSize,
        position watermarkPos: WatermarkPosition,
        opacity: Float
    ) -> CIImage {
        guard let watermark = watermarkImage else {
            return image
        }

        // Calculate watermark position
        let position = calculateWatermarkPosition(
            screenSize: screenSize,
            watermarkSize: watermark.extent.size,
            position: watermarkPos,
        )

        // Position watermark
        let positionedWatermark = watermark.transformed(
            by: CGAffineTransform(translationX: position.x, y: position.y),
        )

        // Apply opacity
        let transparentWatermark = positionedWatermark.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
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

    private func pipSize(for screenSize: CGSize, cameraCount: Int, pipScale: Float) -> CGSize {
        guard pipScale.isFinite, pipScale > 0 else { return .zero }

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
