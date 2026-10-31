import CoreGraphics
import Testing

@testable import ArkavoRecorder

private func isClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.01) -> Bool {
    abs(a.minX - b.minX) <= tolerance
        && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance
        && abs(a.height - b.height) <= tolerance
}

struct AvatarSlotLayoutTests {
    let tex = CGSize(width: 1920, height: 1080)
    let aspect070 = CGRect(x: 0.3425, y: 0.1, width: 0.315, height: 0.8)  // 604.8 x 864 px = 0.70
    let gameplayRight = AvatarSlot(
        slot: CGRect(x: 0.71, y: 0.38, width: 0.28, height: 0.62), anchor: .bottomRight)
    let gameplayLeft = AvatarSlot(
        slot: CGRect(x: 0.01, y: 0.38, width: 0.28, height: 0.62), anchor: .bottomLeft)
    let artLeft = AvatarSlot(
        slot: CGRect(x: 0.02, y: 0.42, width: 0.20, height: 0.46), anchor: .bottomLeft)

    @Test("The study's worked example: a 0.70 avatar in Gameplay right at 1080p")
    func workedExample() {
        let f = AvatarSlotLayout.frame(
            slot: gameplayRight, visibleRect: aspect070, textureSize: tex,
            output: CGSize(width: 1920, height: 1080))
        #expect(isClose(f.visible, CGRect(x: 1432.08, y: 410.4, width: 468.72, height: 669.6)))
        #expect(abs(f.visible.maxX - 1900.8) < 0.01)
        #expect(abs(f.visible.maxY - 1080) < 0.01)
        #expect(isClose(f.textureFrame, CGRect(x: 922.44, y: 326.7, width: 1488, height: 837)))
    }

    @Test("Placement is the same normalized rect at 720p, 1080p and 4K")
    func resolutionIndependent() {
        let f720 = AvatarSlotLayout.frame(
            slot: gameplayRight, visibleRect: aspect070, textureSize: tex,
            output: CGSize(width: 1280, height: 720))
        #expect(isClose(f720.visible, CGRect(x: 954.72, y: 273.6, width: 312.48, height: 446.4)))
        #expect(isClose(f720.textureFrame, CGRect(x: 614.96, y: 217.8, width: 992, height: 558)))

        let f1080 = AvatarSlotLayout.frame(
            slot: gameplayRight, visibleRect: aspect070, textureSize: tex,
            output: CGSize(width: 1920, height: 1080))

        let f4k = AvatarSlotLayout.frame(
            slot: gameplayRight, visibleRect: aspect070, textureSize: tex,
            output: CGSize(width: 3840, height: 2160))
        #expect(isClose(f4k.visible, CGRect(x: 2864.16, y: 820.8, width: 937.44, height: 1339.2)))
        #expect(isClose(f4k.textureFrame, CGRect(x: 1844.88, y: 653.4, width: 2976, height: 1674)))

        let expected = CGRect(x: 0.745875, y: 0.38, width: 0.244125, height: 0.62)
        for (f, size) in [
            (f720, CGSize(width: 1280, height: 720)),
            (f1080, CGSize(width: 1920, height: 1080)),
            (f4k, CGSize(width: 3840, height: 2160)),
        ] {
            let n = CGRect(
                x: f.visible.minX / size.width, y: f.visible.minY / size.height,
                width: f.visible.width / size.width, height: f.visible.height / size.height)
            #expect(isClose(n, expected, tolerance: 1e-9))
        }
    }

    @Test("Bottom-center anchors: the whole Conversation slot and a width-limited half")
    func bottomCenter() {
        let output = CGSize(width: 1920, height: 1080)
        let conversation = AvatarSlot(
            slot: CGRect(x: 0.22, y: 0.08, width: 0.56, height: 0.92), anchor: .bottomCenter)
        let whole = AvatarSlotLayout.frame(
            slot: conversation, visibleRect: aspect070, textureSize: tex, output: output)
        #expect(isClose(whole.visible, CGRect(x: 612.24, y: 86.4, width: 695.52, height: 993.6)))
        #expect(abs(whole.visible.midX - 960) < 0.01)

        let creatorHalf = AvatarSlot(
            slot: CGRect(x: 0.22, y: 0.08, width: 0.28, height: 0.92), anchor: .bottomCenter)
        let half = AvatarSlotLayout.frame(
            slot: creatorHalf, visibleRect: aspect070, textureSize: tex, output: output)
        #expect(isClose(half.visible, CGRect(x: 422.4, y: 312, width: 537.6, height: 768)))
        #expect(abs(half.visible.maxY - 1080) < 0.01)
    }

    @Test("Bottom-left anchor keeps the left edge on the slot")
    func bottomLeft() {
        let output = CGSize(width: 1920, height: 1080)
        let g = AvatarSlotLayout.frame(
            slot: gameplayLeft, visibleRect: aspect070, textureSize: tex, output: output)
        #expect(isClose(g.visible, CGRect(x: 19.2, y: 410.4, width: 468.72, height: 669.6)))
        #expect(abs(g.textureFrame.minX - -490.44) < 0.01)

        let a = AvatarSlotLayout.frame(
            slot: artLeft, visibleRect: aspect070, textureSize: tex, output: output)
        #expect(isClose(a.visible, CGRect(x: 38.4, y: 453.6, width: 347.76, height: 496.8)))
        #expect(abs(a.visible.maxY - 950.4) < 0.01)
    }

    @Test("A full-texture visible rect fits the 16:9 texture")
    func fullTexture() {
        let f = AvatarSlotLayout.frame(
            slot: gameplayRight, visibleRect: AvatarSlotLayout.fullTexture, textureSize: tex,
            output: CGSize(width: 1920, height: 1080))
        let expected = CGRect(x: 1363.2, y: 777.6, width: 537.6, height: 302.4)
        #expect(isClose(f.visible, expected))
        #expect(isClose(f.textureFrame, expected))
    }

    @Test("Degenerate inputs")
    func degenerate() {
        let output = CGSize(width: 1920, height: 1080)
        let full = AvatarSlotLayout.frame(
            slot: gameplayRight, visibleRect: AvatarSlotLayout.fullTexture, textureSize: tex,
            output: output)

        let zero = AvatarSlotLayout.frame(
            slot: gameplayRight, visibleRect: .zero, textureSize: tex, output: output)
        #expect(isClose(zero.visible, full.visible))
        #expect(isClose(zero.textureFrame, full.textureFrame))

        let outside = AvatarSlotLayout.frame(
            slot: gameplayRight, visibleRect: CGRect(x: 2, y: 2, width: 1, height: 1),
            textureSize: tex, output: output)
        #expect(isClose(outside.visible, full.visible))

        // (-0.1, 0, 0.6, 1) intersects the unit rect to (0, 0, 0.5, 1)
        let clipped = AvatarSlotLayout.frame(
            slot: gameplayRight, visibleRect: CGRect(x: -0.1, y: 0, width: 0.6, height: 1),
            textureSize: tex, output: output)
        let explicit = AvatarSlotLayout.frame(
            slot: gameplayRight, visibleRect: CGRect(x: 0, y: 0, width: 0.5, height: 1),
            textureSize: tex, output: output)
        #expect(isClose(clipped.visible, explicit.visible))
        #expect(isClose(clipped.textureFrame, explicit.textureFrame))
        #expect(isClose(clipped.visible, CGRect(x: 1363.2, y: 475.2, width: 537.6, height: 604.8)))
        #expect(isClose(clipped.textureFrame, CGRect(x: 1363.2, y: 475.2, width: 1075.2, height: 604.8)))

        let noOutput = AvatarSlotLayout.frame(
            slot: gameplayRight, visibleRect: aspect070, textureSize: tex, output: .zero)
        #expect(noOutput.visible == .zero)
        #expect(noOutput.textureFrame == .zero)

        let noTexture = AvatarSlotLayout.frame(
            slot: gameplayRight, visibleRect: aspect070, textureSize: .zero, output: output)
        #expect(noTexture.visible == .zero)
        #expect(noTexture.textureFrame == .zero)
    }

    @Test("Top-left to Core Image bottom-left conversion")
    func coreImageConversion() {
        let v = AvatarSlotLayout.coreImageRect(
            CGRect(x: 1432.08, y: 410.4, width: 468.72, height: 669.6), outputHeight: 1080)
        #expect(isClose(v, CGRect(x: 1432.08, y: 0, width: 468.72, height: 669.6)))
        let t = AvatarSlotLayout.coreImageRect(
            CGRect(x: 922.44, y: 326.7, width: 1488, height: 837), outputHeight: 1080)
        #expect(isClose(t, CGRect(x: 922.44, y: -83.7, width: 1488, height: 837)))
    }

    @Test("Screens fit uniformly, centred")
    func aspectFit() {
        let output = CGSize(width: 1920, height: 1080)
        #expect(isClose(
            AvatarSlotLayout.aspectFit(CGSize(width: 1920, height: 1200), in: output),
            CGRect(x: 96, y: 0, width: 1728, height: 1080)))
        #expect(isClose(
            AvatarSlotLayout.aspectFit(CGSize(width: 1080, height: 1920), in: output),
            CGRect(x: 656.25, y: 0, width: 607.5, height: 1080)))
        #expect(isClose(
            AvatarSlotLayout.aspectFit(CGSize(width: 3440, height: 1440), in: output),
            CGRect(x: 0, y: 138.14, width: 1920, height: 803.72)))
        #expect(isClose(
            AvatarSlotLayout.aspectFit(CGSize(width: 3840, height: 2160), in: output),
            CGRect(x: 0, y: 0, width: 1920, height: 1080)))
        #expect(isClose(
            AvatarSlotLayout.aspectFit(CGSize(width: 1280, height: 720), in: output),
            CGRect(x: 0, y: 0, width: 1920, height: 1080)))
        // Within a pixel of the output on an axis: that axis fills, with no sub-pixel bar.
        // 1366×768 would otherwise fit as (0, 0.26, 1920, 1079.47).
        #expect(isClose(
            AvatarSlotLayout.aspectFit(CGSize(width: 1366, height: 768), in: output),
            CGRect(x: 0, y: 0, width: 1920, height: 1080), tolerance: 1e-9))
        #expect(AvatarSlotLayout.aspectFit(.zero, in: output) == .zero)
        #expect(AvatarSlotLayout.aspectFit(CGSize(width: 1920, height: 1080), in: .zero) == .zero)
    }
}
