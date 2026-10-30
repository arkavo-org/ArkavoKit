import CoreGraphics

/// A region of the output canvas reserved for an avatar, plus the edge the avatar
/// stays pinned to inside it.
///
/// `slot` is normalized to the output (0...1) with a top-left origin, so the same
/// slot describes the same placement at every output resolution.
public struct AvatarSlot: Sendable, Equatable {
    /// The edge of the slot the fitted avatar stays on. The avatar always rests on
    /// the slot's bottom edge; this picks the horizontal alignment.
    public enum Anchor: Sendable, Equatable {
        /// The avatar's left edge stays on the slot's left edge.
        case bottomLeft
        /// The avatar's right edge stays on the slot's right edge.
        case bottomRight
        /// The avatar is centred horizontally in the slot.
        case bottomCenter
    }

    /// The slot in normalized output coordinates, top-left origin.
    public var slot: CGRect
    /// The horizontal alignment of the avatar within the slot.
    public var anchor: Anchor

    /// A slot from a normalized, top-left-origin output rect and the anchor that aligns the avatar in it.
    public init(slot: CGRect, anchor: Anchor) {
        self.slot = slot
        self.anchor = anchor
    }
}

/// The slot math the live preview and the compositor share, so both place an
/// avatar identically.
public enum AvatarSlotLayout {
    /// The whole avatar texture, in normalized top-left coordinates.
    public static let fullTexture = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Fits the visible part of an avatar texture into a slot and returns where it lands.
    ///
    /// The visible part is scaled by one uniform factor, the largest that fits the slot,
    /// so it is never stretched. It rests on the slot's bottom edge and is aligned by the
    /// slot's anchor. Everything is a pure function of its inputs and independent of
    /// output resolution: the same normalized inputs give the same normalized result.
    ///
    /// - Parameters:
    ///   - slot: The target slot, normalized to the output.
    ///   - visibleRect: The part of the texture that holds the avatar, normalized,
    ///     top-left origin. It is intersected with the unit rect first; an empty or
    ///     out-of-range rect is treated as ``fullTexture``.
    ///   - textureSize: The avatar texture size in pixels.
    ///   - output: The output canvas size in pixels.
    /// - Returns: `visible`, where the visible part lands, and `textureFrame`, where the
    ///   whole texture lands so that its visible part coincides with `visible`. Both are
    ///   in top-left output pixels. Both are `.zero` when `output` or `textureSize` is
    ///   degenerate, or when the slot has no area.
    public static func frame(
        slot: AvatarSlot,
        visibleRect: CGRect,
        textureSize: CGSize,
        output: CGSize
    ) -> (visible: CGRect, textureFrame: CGRect) {
        guard output.width > 0, output.height > 0, textureSize.width > 0, textureSize.height > 0
        else { return (.zero, .zero) }

        var vr = visibleRect.intersection(fullTexture)
        if vr.isNull || vr.isInfinite || vr.width <= 0 || vr.height <= 0 { vr = fullTexture }

        let tw = textureSize.width
        let th = textureSize.height
        let pw = vr.width * tw
        let ph = vr.height * th

        let sx = slot.slot.minX * output.width
        let sy = slot.slot.minY * output.height
        let sw = slot.slot.width * output.width
        let sh = slot.slot.height * output.height
        guard sw > 0, sh > 0 else { return (.zero, .zero) }

        let k = min(sw / pw, sh / ph)
        let w = pw * k
        let h = ph * k
        let y = sy + sh - h
        let x: CGFloat
        switch slot.anchor {
        case .bottomLeft: x = sx
        case .bottomRight: x = sx + sw - w
        case .bottomCenter: x = sx + (sw - w) / 2
        }

        let visible = CGRect(x: x, y: y, width: w, height: h)
        let textureFrame = CGRect(
            x: x - vr.minX * tw * k, y: y - vr.minY * th * k, width: tw * k, height: th * k)
        return (visible, textureFrame)
    }

    /// Fits a source of the given size inside the output, uniformly and centred.
    ///
    /// Returns a top-left rect in output pixels; the source is not stretched, so the unused
    /// axis is left as bars. One exception: a fit within a pixel of the output on an axis fills
    /// that axis, because a bar under a pixel would only darken the edge rows (1366×768 fits as
    /// 1920×1079.47). Returns `.zero` when either size is degenerate.
    static func aspectFit(_ source: CGSize, in output: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, output.width > 0, output.height > 0
        else { return .zero }
        let scale = min(output.width / source.width, output.height / source.height)
        var w = source.width * scale
        var h = source.height * scale
        if output.width - w < 1 { w = output.width }
        if output.height - h < 1 { h = output.height }
        return CGRect(x: (output.width - w) / 2, y: (output.height - h) / 2, width: w, height: h)
    }

    /// Converts a top-left rect to Core Image's bottom-left origin for an output of the
    /// given height: `y = outputHeight - y - height`. Size and x are unchanged.
    static func coreImageRect(_ rect: CGRect, outputHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: outputHeight - rect.minY - rect.height, width: rect.width, height: rect.height)
    }
}
