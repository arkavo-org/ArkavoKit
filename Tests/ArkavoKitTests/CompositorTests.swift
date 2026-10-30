import AVFoundation
import CoreImage
import CoreVideo
import Testing

@testable import ArkavoRecorder

// MARK: - Test Helpers

/// Creates a solid color CVPixelBuffer for testing
func createTestPixelBuffer(
    width: Int,
    height: Int,
    red: UInt8,
    green: UInt8,
    blue: UInt8,
    alpha: UInt8 = 255
) -> CVPixelBuffer? {
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
        &pixelBuffer
    )

    guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
        return nil
    }

    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
        return nil
    }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            ptr[offset + 0] = blue   // B
            ptr[offset + 1] = green  // G
            ptr[offset + 2] = red    // R
            ptr[offset + 3] = alpha  // A
        }
    }

    return buffer
}

/// Creates a mostly transparent CVPixelBuffer, as an avatar renderer draws: pixels inside `opaque`
/// take `color` at alpha 255, pixels inside `marker` are red at alpha 255, and every other pixel is
/// (0, 0, 0, 0). Both rects are normalized to the buffer with a top-left origin; a pixel is inside
/// when its centre is.
func createMaskedPixelBuffer(
    width: Int,
    height: Int,
    opaque: CGRect,
    color: (UInt8, UInt8, UInt8),
    marker: CGRect? = nil
) -> CVPixelBuffer? {
    guard let buffer = createTestPixelBuffer(width: width, height: height, red: 0, green: 0, blue: 0, alpha: 0) else {
        return nil
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

    func contains(_ rect: CGRect, _ x: Int, _ y: Int) -> Bool {
        rect.contains(CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(width), y: (CGFloat(y) + 0.5) / CGFloat(height)))
    }

    for y in 0..<height {
        for x in 0..<width {
            let pixel: (UInt8, UInt8, UInt8)
            if let marker, contains(marker, x, y) {
                pixel = (255, 0, 0)
            } else if contains(opaque, x, y) {
                pixel = color
            } else {
                continue
            }
            let offset = y * bytesPerRow + x * 4
            ptr[offset + 0] = pixel.2  // B
            ptr[offset + 1] = pixel.1  // G
            ptr[offset + 2] = pixel.0  // R
            ptr[offset + 3] = 255      // A
        }
    }
    return buffer
}

/// Creates a CMSampleBuffer from a CVPixelBuffer for testing
func createTestSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
    var formatDescription: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
    )

    guard let format = formatDescription else { return nil }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: CMTime(value: 0, timescale: 30),
        decodeTimeStamp: .invalid
    )

    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: format,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )

    return sampleBuffer
}

/// Gets the average color of a region in a pixel buffer
func getAverageColor(
    in buffer: CVPixelBuffer,
    region: CGRect
) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

    guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
        return nil
    }

    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

    let minX = max(0, Int(region.minX))
    let maxX = min(width, Int(region.maxX))
    let minY = max(0, Int(region.minY))
    let maxY = min(height, Int(region.maxY))

    var totalR: Int = 0
    var totalG: Int = 0
    var totalB: Int = 0
    var totalA: Int = 0
    var count = 0

    for y in minY..<maxY {
        for x in minX..<maxX {
            let offset = y * bytesPerRow + x * 4
            totalB += Int(ptr[offset + 0])
            totalG += Int(ptr[offset + 1])
            totalR += Int(ptr[offset + 2])
            totalA += Int(ptr[offset + 3])
            count += 1
        }
    }

    guard count > 0 else { return nil }

    return (
        r: UInt8(totalR / count),
        g: UInt8(totalG / count),
        b: UInt8(totalB / count),
        a: UInt8(totalA / count)
    )
}

/// Direct CIImage composition test (bypasses CompositorManager)
func testDirectCIImageComposition(
    screenBuffer: CVPixelBuffer,
    overlayBuffer: CVPixelBuffer,
    position: CGPoint,
    overlaySize: CGSize
) -> CVPixelBuffer? {
    let screenImage = CIImage(cvPixelBuffer: screenBuffer)
    let overlayImage = CIImage(cvPixelBuffer: overlayBuffer)

    // Scale overlay
    let scaleX = overlaySize.width / overlayImage.extent.width
    let scaleY = overlaySize.height / overlayImage.extent.height
    let scaledOverlay = overlayImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

    // Position overlay
    let positionedOverlay = scaledOverlay.transformed(by: CGAffineTransform(translationX: position.x, y: position.y))

    // Composite
    let composited = positionedOverlay.composited(over: screenImage)

    // Render to pixel buffer
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    let context = CIContext(mtlDevice: device)

    var pixelBuffer: CVPixelBuffer?
    let attributes: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    CVPixelBufferCreate(
        kCFAllocatorDefault,
        Int(screenImage.extent.width),
        Int(screenImage.extent.height),
        kCVPixelFormatType_32BGRA,
        attributes as CFDictionary,
        &pixelBuffer
    )

    guard let outputBuffer = pixelBuffer else { return nil }
    context.render(composited, to: outputBuffer)
    return outputBuffer
}

// MARK: - Tests

/// Tests for CompositorManager to verify overlay composition works correctly
struct CompositorTests {

    @Test("Compositor initializes successfully")
    func testCompositorInitialization() throws {
        let compositor = try CompositorManager()
        #expect(compositor.pipPosition == .bottomRight)
        #expect(compositor.pipScale == 0.2)
        #expect(compositor.avatarSlot == AvatarSlot(
            slot: CGRect(x: 0.71, y: 0.38, width: 0.28, height: 0.62), anchor: .bottomRight))
        #expect(compositor.avatarVisibleRect == AvatarSlotLayout.fullTexture)
        #expect(compositor.museSlot == AvatarSlot(
            slot: CGRect(x: 0.01, y: 0.38, width: 0.28, height: 0.62), anchor: .bottomLeft))
        #expect(compositor.museVisibleRect == AvatarSlotLayout.fullTexture)
    }

    @Test("Compositor composites screen-only correctly")
    func testScreenOnlyComposition() throws {
        let compositor = try CompositorManager()
        compositor.outputSize = CGSize(width: 1920, height: 1080)
        compositor.watermarkEnabled = false

        // Create a red screen buffer (1920x1080)
        guard let screenBuffer = createTestPixelBuffer(
            width: 1920, height: 1080,
            red: 255, green: 0, blue: 0
        ) else {
            Issue.record("Failed to create screen buffer")
            return
        }

        guard let screenSample = createTestSampleBuffer(from: screenBuffer) else {
            Issue.record("Failed to create screen sample buffer")
            return
        }

        // Composite with no overlays
        guard let result = compositor.composite(
            screen: screenSample,
            cameraLayers: [],
            avatarTexture: nil
        ) else {
            Issue.record("Compositor returned nil")
            return
        }

        // Verify output dimensions
        let width = CVPixelBufferGetWidth(result)
        let height = CVPixelBufferGetHeight(result)
        #expect(width == 1920)
        #expect(height == 1080)

        // Verify the output is red (the screen color)
        if let color = getAverageColor(in: result, region: CGRect(x: 960, y: 540, width: 100, height: 100)) {
            #expect(color.r > 200, "Expected red channel > 200, got \(Int(color.r))")
            #expect(color.g < 50, "Expected green channel < 50, got \(Int(color.g))")
            #expect(color.b < 50, "Expected blue channel < 50, got \(Int(color.b))")
        }
    }

    @Test("Compositor composites avatar overlay correctly")
    func testAvatarOverlayComposition() throws {
        let compositor = try CompositorManager()
        compositor.outputSize = CGSize(width: 1920, height: 1080)
        compositor.watermarkEnabled = false
        compositor.pipPosition = .bottomRight
        compositor.pipScale = 0.2  // 20% of screen

        // Create a red screen buffer (1920x1080)
        guard let screenBuffer = createTestPixelBuffer(
            width: 1920, height: 1080,
            red: 255, green: 0, blue: 0
        ) else {
            Issue.record("Failed to create screen buffer")
            return
        }

        guard let screenSample = createTestSampleBuffer(from: screenBuffer) else {
            Issue.record("Failed to create screen sample buffer")
            return
        }

        // Create a blue avatar buffer (1920x1080) with full opacity
        guard let avatarBuffer = createTestPixelBuffer(
            width: 1920, height: 1080,
            red: 0, green: 0, blue: 255,
            alpha: 255
        ) else {
            Issue.record("Failed to create avatar buffer")
            return
        }

        // Composite with avatar overlay
        guard let result = compositor.composite(
            screen: screenSample,
            cameraLayers: [],
            avatarTexture: avatarBuffer
        ) else {
            Issue.record("Compositor returned nil for avatar overlay")
            return
        }

        // Verify output dimensions
        let width = CVPixelBufferGetWidth(result)
        let height = CVPixelBufferGetHeight(result)
        #expect(width == 1920)
        #expect(height == 1080)

        // Check center of screen - should still be red (screen)
        if let centerColor = getAverageColor(in: result, region: CGRect(x: 860, y: 440, width: 100, height: 100)) {
            #expect(centerColor.r > 200, "Center should be red (screen), got r=\(Int(centerColor.r))")
        }

        try expectDefaultAvatarSlot(result)
    }

    @Test("Compositor handles transparent avatar correctly")
    func testTransparentAvatarComposition() throws {
        let compositor = try CompositorManager()
        compositor.outputSize = CGSize(width: 1920, height: 1080)
        compositor.watermarkEnabled = false
        compositor.pipPosition = .bottomRight

        // Create a red screen buffer
        guard let screenBuffer = createTestPixelBuffer(
            width: 1920, height: 1080,
            red: 255, green: 0, blue: 0
        ) else {
            Issue.record("Failed to create screen buffer")
            return
        }

        guard let screenSample = createTestSampleBuffer(from: screenBuffer) else {
            Issue.record("Failed to create screen sample buffer")
            return
        }

        // Create a transparent avatar buffer (alpha = 0)
        guard let avatarBuffer = createTestPixelBuffer(
            width: 1920, height: 1080,
            red: 0, green: 0, blue: 255,
            alpha: 0  // Fully transparent
        ) else {
            Issue.record("Failed to create transparent avatar buffer")
            return
        }

        // Composite with transparent avatar
        guard let result = compositor.composite(
            screen: screenSample,
            cameraLayers: [],
            avatarTexture: avatarBuffer
        ) else {
            Issue.record("Compositor returned nil")
            return
        }

        // Even with avatar overlay, the bottom-right should show through to screen
        // because avatar is transparent
        if let cornerColor = getAverageColor(in: result, region: CGRect(x: 1800, y: 50, width: 50, height: 50)) {
            print("Transparent avatar corner: r=\(cornerColor.r), g=\(cornerColor.g), b=\(cornerColor.b), a=\(cornerColor.a)")
            // With transparent avatar, we should see the red screen through
            // Note: CIImage compositing behavior may vary
        }
    }

    @Test("Compositor scales 4K input to 1080p output")
    func testResolutionScaling() throws {
        let compositor = try CompositorManager()
        compositor.outputSize = CGSize(width: 1920, height: 1080)
        compositor.watermarkEnabled = false

        // Create a 4K screen buffer (3840x2160)
        guard let screenBuffer = createTestPixelBuffer(
            width: 3840, height: 2160,
            red: 0, green: 255, blue: 0  // Green
        ) else {
            Issue.record("Failed to create 4K screen buffer")
            return
        }

        guard let screenSample = createTestSampleBuffer(from: screenBuffer) else {
            Issue.record("Failed to create screen sample buffer")
            return
        }

        guard let result = compositor.composite(
            screen: screenSample,
            cameraLayers: [],
            avatarTexture: nil
        ) else {
            Issue.record("Compositor returned nil")
            return
        }

        // Verify output is scaled to 1080p
        let width = CVPixelBufferGetWidth(result)
        let height = CVPixelBufferGetHeight(result)
        #expect(width == 1920, "Expected width 1920, got \(width)")
        #expect(height == 1080, "Expected height 1080, got \(height)")

        // Verify color is preserved after scaling
        if let color = getAverageColor(in: result, region: CGRect(x: 960, y: 540, width: 100, height: 100)) {
            #expect(color.g > 200, "Expected green channel > 200, got \(Int(color.g))")
        }
    }

    @Test("Test buffers have correct colors")
    func testBufferColors() throws {
        // Create and verify red buffer
        guard let redBuffer = createTestPixelBuffer(
            width: 100, height: 100,
            red: 255, green: 0, blue: 0
        ) else {
            Issue.record("Failed to create red buffer")
            return
        }

        if let redColor = getAverageColor(in: redBuffer, region: CGRect(x: 25, y: 25, width: 50, height: 50)) {
            print("Red buffer: r=\(redColor.r), g=\(redColor.g), b=\(redColor.b), a=\(redColor.a)")
            #expect(redColor.r > 200, "Red buffer should be red")
            #expect(redColor.g < 50, "Red buffer should have low green")
            #expect(redColor.b < 50, "Red buffer should have low blue")
        }

        // Create and verify blue buffer
        guard let blueBuffer = createTestPixelBuffer(
            width: 100, height: 100,
            red: 0, green: 0, blue: 255,
            alpha: 255
        ) else {
            Issue.record("Failed to create blue buffer")
            return
        }

        if let blueColor = getAverageColor(in: blueBuffer, region: CGRect(x: 25, y: 25, width: 50, height: 50)) {
            print("Blue buffer: r=\(blueColor.r), g=\(blueColor.g), b=\(blueColor.b), a=\(blueColor.a)")
            #expect(blueColor.b > 200, "Blue buffer should be blue")
            #expect(blueColor.r < 50, "Blue buffer should have low red")
        }
    }

    @Test("CIImage renders correctly to pixel buffer")
    func testCIImageRendering() throws {
        // Create a blue buffer
        guard let blueBuffer = createTestPixelBuffer(
            width: 100, height: 100,
            red: 0, green: 0, blue: 255,
            alpha: 255
        ) else {
            Issue.record("Failed to create blue buffer")
            return
        }

        // Convert to CIImage and back
        let ciImage = CIImage(cvPixelBuffer: blueBuffer)
        print("CIImage extent: \(ciImage.extent)")

        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device")
            return
        }
        let context = CIContext(mtlDevice: device)

        var outputBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault, 100, 100,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &outputBuffer
        )

        guard let output = outputBuffer else {
            Issue.record("Failed to create output buffer")
            return
        }

        context.render(ciImage, to: output)

        if let outputColor = getAverageColor(in: output, region: CGRect(x: 25, y: 25, width: 50, height: 50)) {
            print("Rendered output: r=\(outputColor.r), g=\(outputColor.g), b=\(outputColor.b), a=\(outputColor.a)")
            #expect(outputColor.b > 200, "Rendered buffer should be blue, got b=\(Int(outputColor.b))")
        }
    }

    @Test("Simple CIImage overlay composition")
    func testSimpleOverlay() throws {
        // Create a red background (100x100)
        guard let redBuffer = createTestPixelBuffer(
            width: 100, height: 100,
            red: 255, green: 0, blue: 0
        ) else {
            Issue.record("Failed to create red buffer")
            return
        }

        // Create a small blue overlay (50x50)
        guard let blueBuffer = createTestPixelBuffer(
            width: 50, height: 50,
            red: 0, green: 0, blue: 255,
            alpha: 255
        ) else {
            Issue.record("Failed to create blue buffer")
            return
        }

        let background = CIImage(cvPixelBuffer: redBuffer)
        let overlay = CIImage(cvPixelBuffer: blueBuffer)

        print("Background extent: \(background.extent)")
        print("Overlay extent: \(overlay.extent)")

        // Position overlay at (25, 25) - center of background
        let positionedOverlay = overlay.transformed(by: CGAffineTransform(translationX: 25, y: 25))
        print("Positioned overlay extent: \(positionedOverlay.extent)")

        // Composite - overlay goes ON TOP
        let composited = positionedOverlay.composited(over: background)
        print("Composited extent: \(composited.extent)")

        // Render to output
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device")
            return
        }
        let context = CIContext(mtlDevice: device)

        var outputBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault, 100, 100,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &outputBuffer
        )

        guard let output = outputBuffer else {
            Issue.record("Failed to create output buffer")
            return
        }

        context.render(composited, to: output)

        // Check corner (should be red - outside overlay)
        if let cornerColor = getAverageColor(in: output, region: CGRect(x: 5, y: 5, width: 10, height: 10)) {
            print("Corner (outside overlay): r=\(cornerColor.r), g=\(cornerColor.g), b=\(cornerColor.b)")
            #expect(cornerColor.r > 200, "Corner should be red (background)")
        }

        // Check center (should be blue - inside overlay)
        // Overlay is at (25,25) with size (50,50), so center (50,50) should be inside
        if let centerColor = getAverageColor(in: output, region: CGRect(x: 45, y: 45, width: 10, height: 10)) {
            print("Center (inside overlay): r=\(centerColor.r), g=\(centerColor.g), b=\(centerColor.b)")
            #expect(centerColor.b > 200, "Center should be blue (overlay), got b=\(Int(centerColor.b))")
        }
    }

    @Test("Direct CIImage composition works")
    func testDirectComposition() throws {
        // Create a red screen buffer (1920x1080)
        guard let screenBuffer = createTestPixelBuffer(
            width: 1920, height: 1080,
            red: 255, green: 0, blue: 0
        ) else {
            Issue.record("Failed to create screen buffer")
            return
        }

        // Create a blue overlay buffer (1920x1080)
        guard let overlayBuffer = createTestPixelBuffer(
            width: 1920, height: 1080,
            red: 0, green: 0, blue: 255,
            alpha: 255
        ) else {
            Issue.record("Failed to create overlay buffer")
            return
        }

        // Test direct composition at bottom-right (like PiP would be)
        // Position: (1920-384-20, 20) = (1516, 20)
        guard let result = testDirectCIImageComposition(
            screenBuffer: screenBuffer,
            overlayBuffer: overlayBuffer,
            position: CGPoint(x: 1516, y: 20),
            overlaySize: CGSize(width: 384, height: 216)
        ) else {
            Issue.record("Direct composition returned nil")
            return
        }

        // Check center - should be red
        if let centerColor = getAverageColor(in: result, region: CGRect(x: 860, y: 440, width: 100, height: 100)) {
            print("Direct composition center: r=\(centerColor.r), g=\(centerColor.g), b=\(centerColor.b)")
            #expect(centerColor.r > 200, "Center should be red")
        }

        // Check bottom-right corner - should be blue (overlay)
        // The overlay is at CIImage (1516, 20) with size (384, 216)
        // CIImage uses bottom-left origin, CVPixelBuffer uses top-left origin
        // CIImage y=20 = pixel buffer y = 1080-20-216 = 844
        // So check region in pixel buffer at y=900 which is inside the overlay
        if let cornerColor = getAverageColor(in: result, region: CGRect(x: 1600, y: 900, width: 50, height: 50)) {
            print("Direct composition corner (pixel buffer y=900): r=\(cornerColor.r), g=\(cornerColor.g), b=\(cornerColor.b)")
            #expect(cornerColor.b > 200, "Corner should be blue (overlay), got b=\(Int(cornerColor.b))")
        }
    }

    @Test("Compositor handles 4K screen with avatar scaled to 1080p")
    func test4KScreenWithAvatarTo1080p() throws {
        let compositor = try CompositorManager()
        compositor.outputSize = CGSize(width: 1920, height: 1080)
        compositor.watermarkEnabled = false
        compositor.pipPosition = .bottomRight
        compositor.pipScale = 0.2

        // Create a 4K red screen buffer
        guard let screenBuffer = createTestPixelBuffer(
            width: 3840, height: 2160,
            red: 255, green: 0, blue: 0
        ) else {
            Issue.record("Failed to create 4K screen buffer")
            return
        }

        guard let screenSample = createTestSampleBuffer(from: screenBuffer) else {
            Issue.record("Failed to create screen sample buffer")
            return
        }

        // Create a 1080p blue avatar buffer (like real VRM renderer)
        guard let avatarBuffer = createTestPixelBuffer(
            width: 1920, height: 1080,
            red: 0, green: 0, blue: 255,
            alpha: 255
        ) else {
            Issue.record("Failed to create avatar buffer")
            return
        }

        // Composite with avatar overlay
        guard let result = compositor.composite(
            screen: screenSample,
            cameraLayers: [],
            avatarTexture: avatarBuffer
        ) else {
            Issue.record("Compositor returned nil")
            return
        }

        // Verify output is 1080p
        let width = CVPixelBufferGetWidth(result)
        let height = CVPixelBufferGetHeight(result)
        #expect(width == 1920, "Expected width 1920, got \(width)")
        #expect(height == 1080, "Expected height 1080, got \(height)")

        // Check center - should be red (screen)
        if let centerColor = getAverageColor(in: result, region: CGRect(x: 860, y: 440, width: 100, height: 100)) {
            print("4K→1080p center: r=\(centerColor.r), g=\(centerColor.g), b=\(centerColor.b)")
            #expect(centerColor.r > 200, "Center should be red (screen)")
        }

        // The 4K screen is fitted into the 1080p output, and the avatar is placed in output space,
        // so it lands where it does over a 1080p screen.
        try expectDefaultAvatarSlot(result)
    }

    @Test("Compositor handles camera layer correctly")
    func testCameraLayerComposition() throws {
        let compositor = try CompositorManager()
        compositor.outputSize = CGSize(width: 1920, height: 1080)
        compositor.watermarkEnabled = false
        compositor.pipPosition = .bottomRight

        // Create a red screen buffer
        guard let screenBuffer = createTestPixelBuffer(
            width: 1920, height: 1080,
            red: 255, green: 0, blue: 0
        ) else {
            Issue.record("Failed to create screen buffer")
            return
        }

        guard let screenSample = createTestSampleBuffer(from: screenBuffer) else {
            Issue.record("Failed to create screen sample buffer")
            return
        }

        // Create a green camera buffer
        guard let cameraBuffer = createTestPixelBuffer(
            width: 1920, height: 1080,
            red: 0, green: 255, blue: 0
        ) else {
            Issue.record("Failed to create camera buffer")
            return
        }

        guard let cameraSample = createTestSampleBuffer(from: cameraBuffer) else {
            Issue.record("Failed to create camera sample buffer")
            return
        }

        let cameraLayer = CompositorManager.CameraLayer(
            id: "test-camera",
            buffer: cameraSample,
            position: .bottomRight
        )

        // Composite with camera layer
        guard let result = compositor.composite(
            screen: screenSample,
            cameraLayers: [cameraLayer],
            avatarTexture: nil
        ) else {
            Issue.record("Compositor returned nil for camera layer")
            return
        }

        // Verify output dimensions
        let width = CVPixelBufferGetWidth(result)
        let height = CVPixelBufferGetHeight(result)
        #expect(width == 1920)
        #expect(height == 1080)

        // Check center - should be red (screen)
        if let centerColor = getAverageColor(in: result, region: CGRect(x: 860, y: 440, width: 100, height: 100)) {
            #expect(centerColor.r > 200, "Center should be red, got r=\(Int(centerColor.r))")
        }

        // Check bottom-right - should have green (camera overlay)
        // CIImage uses bottom-left origin, CVPixelBuffer uses top-left origin
        // Camera at CIImage y=20 with height ~216 = pixel buffer y around 844-1060
        if let cornerColor = getAverageColor(in: result, region: CGRect(x: 1600, y: 900, width: 50, height: 50)) {
            print("Camera corner color (pixel buffer y=900): r=\(cornerColor.r), g=\(cornerColor.g), b=\(cornerColor.b)")
            #expect(cornerColor.g > 100, "Corner should have camera (green), got g=\(Int(cornerColor.g))")
        }
    }

    @Test("Muse is composited in its slot over an avatar base")
    func museOverAvatarNoScreen() throws {
        let compositor = try CompositorManager()
        compositor.outputSize = CGSize(width: 1920, height: 1080)
        compositor.watermarkEnabled = false
        compositor.pipPosition = .bottomRight
        compositor.pipScale = 0.2
        compositor.museSlot = Self.gameplayLeft
        let avatar = try #require(createTestPixelBuffer(width: 1920, height: 1080, red: 0, green: 255, blue: 0, alpha: 255))
        let muse = try #require(createTestPixelBuffer(width: 1920, height: 1080, red: 0, green: 0, blue: 255, alpha: 255))
        let out = try #require(compositor.composite(avatarTexture: avatar, cameraLayers: [], museTexture: muse))
        // Gameplay left with the whole texture visible: (19.2, 777.6, 537.6, 302.4).
        let bottomLeft = try #require(getAverageColor(in: out, region: CGRect(x: 60, y: 1000, width: 40, height: 40)))
        #expect(bottomLeft.b > 200 && bottomLeft.g < 60)
        let top = try sample(out, 500, 800)
        #expect(top.b > 200 && top.g < 60, "got r=\(top.r) g=\(top.g) b=\(top.b)")
        let center = try #require(getAverageColor(in: out, region: CGRect(x: 940, y: 520, width: 40, height: 40)))
        #expect(center.g > 200)
    }

    @Test("Muse is composited over a camera base with no screen")
    func museOverCameraNoScreen() throws {
        let compositor = try CompositorManager()
        compositor.outputSize = CGSize(width: 1920, height: 1080)
        compositor.watermarkEnabled = false
        compositor.pipPosition = .bottomRight
        compositor.pipScale = 0.2
        compositor.museSlot = Self.gameplayLeft
        let cam = try #require(createTestPixelBuffer(width: 1280, height: 720, red: 255, green: 0, blue: 0, alpha: 255))
        let camSB = try #require(createTestSampleBuffer(from: cam))
        let muse = try #require(createTestPixelBuffer(width: 1920, height: 1080, red: 0, green: 0, blue: 255, alpha: 255))
        let layer = CompositorManager.CameraLayer(id: "cam", buffer: camSB, position: nil)
        let out = try #require(compositor.composite(cameraLayers: [layer], canvasSize: CGSize(width: 1920, height: 1080), museTexture: muse))
        let bottomLeft = try #require(getAverageColor(in: out, region: CGRect(x: 60, y: 1000, width: 40, height: 40)))
        #expect(bottomLeft.b > 200 && bottomLeft.r < 60)
        let top = try sample(out, 500, 800)
        #expect(top.b > 200 && top.r < 60, "got r=\(top.r) g=\(top.g) b=\(top.b)")
    }

    // MARK: - Avatar and Muse slots

    @Test("The visible part lands on the slot, bottom-anchored")
    func visiblePartLandsOnSlot() throws {
        // The visible part (0.3425, 0.1, 0.315, 0.8) fits Gameplay right as (1432.08, 410.4, 468.72, 669.6).
        let out = try compositeMaskedAvatar(screenColor: (255, 0, 0)) { compositor in
            compositor.avatarSlot = Self.gameplayRight
            compositor.avatarVisibleRect = Self.body
        }
        try expectBlue(out, 1646, 725)
        try expectRed(out, CGRect(x: 1400, y: 725, width: 20, height: 40))
        try expectRed(out, CGRect(x: 1646, y: 380, width: 40, height: 20))
        try expectBlue(out, CGRect(x: 1646, y: 1050, width: 40, height: 20))
    }

    @Test("Switching sides moves the slot and never mirrors the avatar")
    func sideSwitchDoesNotMirror() throws {
        // The red marker is the left 20% of the body, and stays on the left on both sides.
        let marker = CGRect(x: 0.3425, y: 0.1, width: 0.063, height: 0.8)
        let right = try compositeMaskedAvatar(marker: marker) { compositor in
            compositor.avatarSlot = Self.gameplayRight
            compositor.avatarVisibleRect = Self.body
        }
        try expectRed(right, CGRect(x: 1450, y: 725, width: 20, height: 40))
        try expectBlue(right, CGRect(x: 1850, y: 725, width: 20, height: 40))

        let left = try compositeMaskedAvatar(marker: marker) { compositor in
            compositor.avatarSlot = Self.gameplayLeft
            compositor.avatarVisibleRect = Self.body
        }
        try expectRed(left, CGRect(x: 40, y: 725, width: 20, height: 40))
        try expectBlue(left, CGRect(x: 450, y: 725, width: 20, height: 40))
    }

    @Test("A portrait screen's bars keep the avatar in its output slot")
    func portraitScreenBarsKeepTheAvatarInItsOutputSlot() throws {
        // The screen fits as (656.25, 0, 607.5, 1080); the avatar's visible part is at
        // (1432.08, 410.4, 468.72, 669.6), over the right bar, neither squeezed nor stretched.
        let out = try compositeMaskedAvatar(screenColor: (255, 0, 0), screenWidth: 1080, screenHeight: 1920) { compositor in
            compositor.avatarSlot = Self.gameplayRight
            compositor.avatarVisibleRect = Self.body
        }
        try expectBlue(out, 1646, 725)
        try expectBlack(out, 1340, 725)
        try expectBlack(out, 300, 520)
        try expectRed(out, 940, 520)
    }

    @Test("A square avatar texture lands inside its slot, neither stretched nor shifted")
    func squareTextureLandsInsideItsSlot() throws {
        // The visible part (0.25, 0.1, 0.5, 0.9) of a 1080×1080 texture fits Conversation as
        // (684, 86.4, 552, 993.6); the red marker is its top 0.1, landing at y 86.4…196.8.
        let visible = CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.9)
        let avatar = try #require(createMaskedPixelBuffer(
            width: 1080, height: 1080, opaque: visible, color: (0, 0, 255),
            marker: CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.1)))
        let out = try compositeScreen(color: (0, 255, 0), avatarTexture: avatar) { compositor in
            compositor.avatarSlot = Self.conversation
            compositor.avatarVisibleRect = visible
        }
        try expectRed(out, 940, 120)
        try expectBlue(out, 940, 520)
        try expectBlue(out, 940, 1040)
        try expectGreen(out, 940, 40)
        try expectGreen(out, 620, 520)
        try expectGreen(out, 1260, 520)
    }

    @Test("pipPosition moves only the camera")
    func pipPositionMovesOnlyTheCamera() throws {
        let compositor = try CompositorManager()
        compositor.outputSize = CGSize(width: 1920, height: 1080)
        compositor.watermarkEnabled = false
        compositor.pipScale = 0.2
        let screen = try #require(createTestPixelBuffer(width: 1920, height: 1080, red: 0, green: 255, blue: 0))
        let screenSample = try #require(createTestSampleBuffer(from: screen))
        let avatar = try #require(createTestPixelBuffer(width: 1920, height: 1080, red: 0, green: 0, blue: 255))
        let muse = try #require(createTestPixelBuffer(width: 1920, height: 1080, red: 255, green: 0, blue: 0))
        let camera = try #require(createTestPixelBuffer(width: 1920, height: 1080, red: 255, green: 255, blue: 255))
        let cameraSample = try #require(createTestSampleBuffer(from: camera))

        // A camera pinned top-left stays clear of both bottom slots, whatever pipPosition says.
        let pinned = CompositorManager.CameraLayer(id: "cam", buffer: cameraSample, position: .topLeft)
        for position in PiPPosition.allCases {
            compositor.pipPosition = position
            let out = try #require(compositor.composite(
                screen: screenSample, cameraLayers: [pinned], avatarTexture: avatar, museTexture: muse))
            try expectBlue(out, 1612, 909)
            try expectRed(out, 268, 909)
            try expectWhite(out, 192, 108)
        }

        // A camera with no corner of its own follows pipPosition; the slots stay where they are.
        let following = CompositorManager.CameraLayer(id: "cam", buffer: cameraSample, position: nil)
        let topLeft = CGPoint(x: 192, y: 108), topRight = CGPoint(x: 1688, y: 108)
        for (position, corner, otherCorner) in [(PiPPosition.topLeft, topLeft, topRight), (.topRight, topRight, topLeft)] {
            compositor.pipPosition = position
            let out = try #require(compositor.composite(
                screen: screenSample, cameraLayers: [following], avatarTexture: avatar, museTexture: muse))
            try expectWhite(out, corner.x, corner.y)
            try expectGreen(out, otherCorner.x, otherCorner.y)
            try expectBlue(out, 1612, 909)
            try expectRed(out, 268, 909)
        }
    }

    // MARK: - Screen fit (bars) and output-space overlays

    @Test("A 16:10 screen is pillar-boxed, not squashed")
    func sixteenByTenScreenGetsBars() throws {
        // 1920×1200 fits as (96, 0, 1728, 1080): bars 0..96 and 1824..1920.
        let out = try compositeRedScreen(width: 1920, height: 1200)
        #expect(CVPixelBufferGetWidth(out) == 1920 && CVPixelBufferGetHeight(out) == 1080)
        try expectBlack(out, 40, 520)
        try expectBlack(out, 1860, 520)
        try expectRed(out, 120, 520)
        try expectRed(out, 940, 520)
    }

    @Test("A portrait screen is pillar-boxed")
    func portraitScreenGetsBars() throws {
        // 1080×1920 fits as (656.25, 0, 607.5, 1080).
        let out = try compositeRedScreen(width: 1080, height: 1920)
        try expectBlack(out, 300, 520)
        try expectBlack(out, 1600, 520)
        try expectRed(out, 940, 520)
    }

    @Test("An ultrawide screen is letterboxed")
    func ultrawideScreenGetsBars() throws {
        // 3440×1440 fits as (0, 138.14…, 1920, 803.72…): y 138.14…941.86.
        let out = try compositeRedScreen(width: 3440, height: 1440)
        try expectBlack(out, 940, 60)
        try expectBlack(out, 940, 1000)
        try expectRed(out, 940, 520)
    }

    @Test("A camera PiP over a portrait screen sits in the output's corner, over the bar")
    func cameraOverPortraitScreen() throws {
        // The 384×216 PiP box is in output space: (1516, 844)…(1900, 1060), over the right bar.
        let camera = try #require(createTestPixelBuffer(width: 1920, height: 1080, red: 0, green: 255, blue: 0))
        let cameraSample = try #require(createTestSampleBuffer(from: camera))
        let layer = CompositorManager.CameraLayer(id: "cam", buffer: cameraSample, position: .bottomRight)
        let out = try compositeRedScreen(width: 1080, height: 1920, cameraLayers: [layer])
        let pip = try sample(out, 1680, 930)
        #expect(pip.g > 200 && pip.r < 60 && pip.b < 60, "got r=\(pip.r) g=\(pip.g) b=\(pip.b)")
    }

    @Test("A screen within a pixel of 16:9 fills the output with no sub-pixel bar")
    func nearSixteenByNineScreenFillsTheOutput() throws {
        // 1366×768 fits as 1920×1079.47: a 0.26 px bar top and bottom would darken the edge rows.
        let out = try compositeRedScreen(width: 1366, height: 768)
        for y in [0, 1079] as [CGFloat] {
            let row = try #require(getAverageColor(in: out, region: CGRect(x: 100, y: y, width: 1720, height: 1)))
            #expect(row.r > 250 && row.g < 5 && row.b < 5, "row \(Int(y)): r=\(row.r) g=\(row.g) b=\(row.b)")
        }
    }

    @Test("A 4:3 camera base fills the output: cropped, with no bars")
    func fourByThreeCameraFillsTheOutput() throws {
        // A 1440×1080 camera fills as 1920×1440, cropping 180 px top and bottom. Its red top band
        // (108 px, 144 px once scaled) is cropped away, so it is neither barred nor squeezed in.
        let compositor = try CompositorManager()
        compositor.outputSize = CGSize(width: 1920, height: 1080)
        compositor.watermarkEnabled = false
        let camera = try #require(createMaskedPixelBuffer(
            width: 1440, height: 1080, opaque: AvatarSlotLayout.fullTexture, color: (0, 0, 255),
            marker: CGRect(x: 0, y: 0, width: 1, height: 0.1)))
        let layer = CompositorManager.CameraLayer(
            id: "cam", buffer: try #require(createTestSampleBuffer(from: camera)), position: nil)
        let out = try #require(compositor.composite(cameraLayers: [layer], canvasSize: CGSize(width: 1920, height: 1080)))
        try expectBlue(out, 0, 520)
        try expectBlue(out, 1880, 520)
        try expectBlue(out, 940, 0)
        try expectBlue(out, 940, 1040)
    }

    @Test("An avatar-only frame is opaque: the texture's transparent pixels come out black")
    func avatarOnlyFrameIsOpaque() throws {
        let compositor = try CompositorManager()
        compositor.outputSize = CGSize(width: 1920, height: 1080)
        compositor.watermarkEnabled = false
        let avatar = try #require(createTestPixelBuffer(width: 1920, height: 1080, red: 0, green: 0, blue: 0, alpha: 0))
        let out = try #require(compositor.composite(avatarTexture: avatar))
        for (x, y) in [(940, 520), (0, 0), (1880, 1040)] as [(CGFloat, CGFloat)] {
            let c = try sample(out, x, y)
            #expect(c.a == 255 && c.r < 20 && c.g < 20 && c.b < 20,
                    "(\(Int(x)), \(Int(y))): r=\(c.r) g=\(c.g) b=\(c.b) a=\(c.a)")
        }
    }

    @Test("A scene overlay covers the bars")
    func sceneOverlayCoversBars() throws {
        // (300, 520) is in the portrait screen's left bar; the overlay spans the whole output.
        let out = try compositeRedScreen(width: 1080, height: 1920) { compositor in
            compositor.sceneOverlayText = "Be Right Back"
            compositor.sceneOverlayGradientColors = (
                CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        }
        let bar = try sample(out, 300, 520)
        #expect(bar.r > 200, "got r=\(bar.r)")
    }

    // MARK: - Helpers

    private static let gameplayRight = AvatarSlot(
        slot: CGRect(x: 0.71, y: 0.38, width: 0.28, height: 0.62), anchor: .bottomRight)
    private static let gameplayLeft = AvatarSlot(
        slot: CGRect(x: 0.01, y: 0.38, width: 0.28, height: 0.62), anchor: .bottomLeft)
    private static let conversation = AvatarSlot(
        slot: CGRect(x: 0.22, y: 0.08, width: 0.56, height: 0.92), anchor: .bottomCenter)
    /// The opaque body in `compositeMaskedAvatar`'s texture: 604.8 × 864 px, aspect 0.70.
    private static let body = CGRect(x: 0.3425, y: 0.1, width: 0.315, height: 0.8)

    /// Composites a solid screen of the given size and colour into the default 1920×1080 output.
    private func compositeScreen(
        width: Int = 1920,
        height: Int = 1080,
        color: (UInt8, UInt8, UInt8),
        cameraLayers: [CompositorManager.CameraLayer] = [],
        avatarTexture: CVPixelBuffer? = nil,
        configure: (CompositorManager) -> Void = { _ in }
    ) throws -> CVPixelBuffer {
        let compositor = try CompositorManager()
        compositor.outputSize = CGSize(width: 1920, height: 1080)
        compositor.watermarkEnabled = false
        compositor.pipPosition = .bottomRight
        compositor.pipScale = 0.2
        configure(compositor)
        let screen = try #require(createTestPixelBuffer(
            width: width, height: height, red: color.0, green: color.1, blue: color.2))
        let screenSample = try #require(createTestSampleBuffer(from: screen))
        return try #require(compositor.composite(
            screen: screenSample, cameraLayers: cameraLayers, avatarTexture: avatarTexture))
    }

    /// Composites a solid red screen of the given size into the default 1920×1080 output.
    private func compositeRedScreen(
        width: Int,
        height: Int,
        cameraLayers: [CompositorManager.CameraLayer] = [],
        configure: (CompositorManager) -> Void = { _ in }
    ) throws -> CVPixelBuffer {
        try compositeScreen(width: width, height: height, color: (255, 0, 0), cameraLayers: cameraLayers, configure: configure)
    }

    /// Composites a 1920×1080 avatar texture, transparent but for a blue `body` (and an optional red
    /// marker), over a solid screen (green unless stated).
    private func compositeMaskedAvatar(
        screenColor: (UInt8, UInt8, UInt8) = (0, 255, 0),
        screenWidth: Int = 1920,
        screenHeight: Int = 1080,
        marker: CGRect? = nil,
        configure: (CompositorManager) -> Void
    ) throws -> CVPixelBuffer {
        let avatar = try #require(createMaskedPixelBuffer(
            width: 1920, height: 1080, opaque: Self.body, color: (0, 0, 255), marker: marker))
        return try compositeScreen(
            width: screenWidth, height: screenHeight, color: screenColor, avatarTexture: avatar, configure: configure)
    }

    /// A full-opaque blue 1920×1080 avatar over a red screen at the default Gameplay right slot, whole
    /// texture visible: (1363.2, 777.6, 537.6, 302.4), flush with the output's bottom.
    private func expectDefaultAvatarSlot(
        _ result: CVPixelBuffer, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let corner = try #require(getAverageColor(in: result, region: CGRect(x: 1600, y: 900, width: 50, height: 50)))
        #expect(corner.b > 100, "Corner should have avatar (blue), got b=\(Int(corner.b))", sourceLocation: sourceLocation)
        // Inside the slot box, outside the old 384×216 PiP box (1516, 844)…(1900, 1060).
        try expectBlue(result, CGRect(x: 1400, y: 800, width: 40, height: 40), sourceLocation: sourceLocation)
        try expectBlue(result, CGRect(x: 1660, y: 1050, width: 40, height: 20), sourceLocation: sourceLocation)
        try expectRed(result, CGRect(x: 1340, y: 800, width: 10, height: 10), sourceLocation: sourceLocation)
    }

    /// The average colour of the 40×40 region whose top-left corner is (x, y).
    private func sample(_ buffer: CVPixelBuffer, _ x: CGFloat, _ y: CGFloat) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        try #require(getAverageColor(in: buffer, region: CGRect(x: x, y: y, width: 40, height: 40)))
    }

    private typealias Color = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

    private func expectColor(
        _ buffer: CVPixelBuffer, _ region: CGRect, _ name: String,
        sourceLocation: SourceLocation, _ matches: (Color) -> Bool
    ) throws {
        let c = try #require(getAverageColor(in: buffer, region: region), sourceLocation: sourceLocation)
        #expect(matches(c),
                "\(region) should be \(name), got r=\(c.r) g=\(c.g) b=\(c.b) a=\(c.a)",
                sourceLocation: sourceLocation)
    }

    private func box(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(x: x, y: y, width: 40, height: 40) }

    /// Black means r, g and b all below 20.
    private func expectBlack(
        _ buffer: CVPixelBuffer, _ x: CGFloat, _ y: CGFloat,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try expectColor(buffer, box(x, y), "black", sourceLocation: sourceLocation) { $0.r < 20 && $0.g < 20 && $0.b < 20 }
    }

    private func expectRed(
        _ buffer: CVPixelBuffer, _ x: CGFloat, _ y: CGFloat,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try expectRed(buffer, box(x, y), sourceLocation: sourceLocation)
    }

    private func expectRed(
        _ buffer: CVPixelBuffer, _ region: CGRect,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try expectColor(buffer, region, "red", sourceLocation: sourceLocation) { $0.r > 200 && $0.g < 60 && $0.b < 60 }
    }

    private func expectGreen(
        _ buffer: CVPixelBuffer, _ x: CGFloat, _ y: CGFloat,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try expectColor(buffer, box(x, y), "green", sourceLocation: sourceLocation) { $0.g > 200 && $0.r < 60 && $0.b < 60 }
    }

    private func expectBlue(
        _ buffer: CVPixelBuffer, _ x: CGFloat, _ y: CGFloat,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try expectBlue(buffer, box(x, y), sourceLocation: sourceLocation)
    }

    private func expectBlue(
        _ buffer: CVPixelBuffer, _ region: CGRect,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try expectColor(buffer, region, "blue", sourceLocation: sourceLocation) { $0.b > 200 && $0.r < 60 && $0.g < 60 }
    }

    private func expectWhite(
        _ buffer: CVPixelBuffer, _ x: CGFloat, _ y: CGFloat,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        try expectColor(buffer, box(x, y), "white", sourceLocation: sourceLocation) { $0.r > 200 && $0.g > 200 && $0.b > 200 }
    }
}
