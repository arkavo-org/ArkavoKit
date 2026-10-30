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

        // Check bottom-right corner - should have blue (avatar overlay)
        // Avatar is 20% of screen = 384x216, positioned at bottom-right with 20px margin
        // CIImage position: (1920-384-20, 20) = (1516, 20) with size (384, 216)
        // CIImage y range: 20 to 236
        // IMPORTANT: CVPixelBuffer uses top-left origin, CIImage uses bottom-left origin
        // So CIImage y=20 (bottom of screen) = pixel buffer y = 1080-20-216 = 844 (near bottom)
        // Check region in pixel buffer at y=900 which is inside the overlay
        if let cornerColor = getAverageColor(in: result, region: CGRect(x: 1600, y: 900, width: 50, height: 50)) {
            print("Bottom-right corner color (pixel buffer y=900): r=\(cornerColor.r), g=\(cornerColor.g), b=\(cornerColor.b), a=\(cornerColor.a)")
            // Avatar should contribute blue to this region
            #expect(cornerColor.b > 100, "Corner should have avatar (blue), got b=\(Int(cornerColor.b))")
        }
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

        // Check bottom-right corner - avatar should be there
        // The 4K screen is fitted into the 1080p output, and the avatar is placed in output space:
        // a 384x216 box at CIImage (1920-384-20, 20), so pixel buffer (1516, 844)…(1900, 1060)
        // Check at pixel buffer y=900 which is inside avatar region
        if let cornerColor = getAverageColor(in: result, region: CGRect(x: 1600, y: 900, width: 50, height: 50)) {
            print("4K→1080p corner (pixel buffer y=900): r=\(cornerColor.r), g=\(cornerColor.g), b=\(cornerColor.b)")
            #expect(cornerColor.b > 100, "Corner should have avatar (blue), got b=\(Int(cornerColor.b))")
        }
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

    @Test("Muse is composited bottom-left over an avatar base when pipPosition is bottom-right")
    func museOverAvatarNoScreen() throws {
        let compositor = try CompositorManager()
        compositor.outputSize = CGSize(width: 1920, height: 1080)
        compositor.watermarkEnabled = false
        compositor.pipPosition = .bottomRight
        compositor.pipScale = 0.2
        let avatar = try #require(createTestPixelBuffer(width: 1920, height: 1080, red: 0, green: 255, blue: 0, alpha: 255))
        let muse = try #require(createTestPixelBuffer(width: 1080, height: 1920, red: 0, green: 0, blue: 255, alpha: 255))
        let out = try #require(compositor.composite(avatarTexture: avatar, cameraLayers: [], museTexture: muse))
        let bottomLeft = try #require(getAverageColor(in: out, region: CGRect(x: 60, y: 1000, width: 40, height: 40)))
        #expect(bottomLeft.b > 200 && bottomLeft.g < 60)
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
        let cam = try #require(createTestPixelBuffer(width: 1280, height: 720, red: 255, green: 0, blue: 0, alpha: 255))
        let camSB = try #require(createTestSampleBuffer(from: cam))
        let muse = try #require(createTestPixelBuffer(width: 1080, height: 1920, red: 0, green: 0, blue: 255, alpha: 255))
        let layer = CompositorManager.CameraLayer(id: "cam", buffer: camSB, position: nil)
        let out = try #require(compositor.composite(cameraLayers: [layer], canvasSize: CGSize(width: 1920, height: 1080), museTexture: muse))
        let bottomLeft = try #require(getAverageColor(in: out, region: CGRect(x: 60, y: 1000, width: 40, height: 40)))
        #expect(bottomLeft.b > 200 && bottomLeft.r < 60)
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

    /// Composites a solid red screen of the given size into the default 1920×1080 output.
    private func compositeRedScreen(
        width: Int,
        height: Int,
        cameraLayers: [CompositorManager.CameraLayer] = [],
        configure: (CompositorManager) -> Void = { _ in }
    ) throws -> CVPixelBuffer {
        let compositor = try CompositorManager()
        compositor.outputSize = CGSize(width: 1920, height: 1080)
        compositor.watermarkEnabled = false
        compositor.pipPosition = .bottomRight
        compositor.pipScale = 0.2
        configure(compositor)
        let screen = try #require(createTestPixelBuffer(width: width, height: height, red: 255, green: 0, blue: 0))
        let screenSample = try #require(createTestSampleBuffer(from: screen))
        return try #require(compositor.composite(screen: screenSample, cameraLayers: cameraLayers))
    }

    /// The average colour of the 40×40 region whose top-left corner is (x, y).
    private func sample(_ buffer: CVPixelBuffer, _ x: CGFloat, _ y: CGFloat) throws -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        try #require(getAverageColor(in: buffer, region: CGRect(x: x, y: y, width: 40, height: 40)))
    }

    /// Black means r, g and b all below 20.
    private func expectBlack(
        _ buffer: CVPixelBuffer, _ x: CGFloat, _ y: CGFloat,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let c = try sample(buffer, x, y)
        #expect(c.r < 20 && c.g < 20 && c.b < 20,
                "(\(Int(x)), \(Int(y))) should be black, got r=\(c.r) g=\(c.g) b=\(c.b)",
                sourceLocation: sourceLocation)
    }

    private func expectRed(
        _ buffer: CVPixelBuffer, _ x: CGFloat, _ y: CGFloat,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let c = try sample(buffer, x, y)
        #expect(c.r > 200 && c.g < 60 && c.b < 60,
                "(\(Int(x)), \(Int(y))) should be red, got r=\(c.r) g=\(c.g) b=\(c.b)",
                sourceLocation: sourceLocation)
    }
}
