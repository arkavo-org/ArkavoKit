//
//  AudioMixer.swift
//  ArkavoKit
//
//  Mixes multiple audio CMSampleBuffer streams into a single output.
//  Used to combine microphone audio with Muse TTS audio for streaming.
//

import AVFoundation
import CoreMedia

/// Mixes multiple audio sources into a single output stream
/// Sums PCM samples and applies clipping to prevent distortion
public final class AudioMixer: @unchecked Sendable {
    // MARK: - Properties

    /// Target output format
    private let sampleRate: Double
    private let channels: UInt32

    /// Source buffers keyed by source ID, with latest sample
    private let lock = NSLock()
    private var sourceBuffers: [String: CMSampleBuffer] = [:]
    private var activeSourceIDs: Set<String> = []

    /// Per-source volume/gain (0.0–1.0). Sources not in this dictionary default to 1.0.
    private var sourceGains: [String: Float] = [:]
    private let gainLock = NSLock()

    /// Ducking: reduce other sources when a priority source is active
    /// Key = source ID that triggers ducking, value = attenuation factor (0-1)
    public var duckingRules: [String: Float] = [:]

    /// Default ducking amount when Muse TTS is speaking (0.7 = reduce mic to 70%)
    public var ttsActiveDuckAmount: Float = 0.7

    /// Callback for mixed output
    public var onMixedSample: ((CMSampleBuffer) -> Void)?

    // MARK: - Per-Source Gain

    /// Set volume/gain for a specific source (0.0 = silent, 1.0 = full volume)
    public func setGain(_ gain: Float, for sourceID: String) {
        gainLock.lock()
        sourceGains[sourceID] = max(0, min(1, gain))
        gainLock.unlock()
    }

    /// Get current gain for a source (defaults to 1.0)
    public func gain(for sourceID: String) -> Float {
        gainLock.lock()
        defer { gainLock.unlock() }
        return sourceGains[sourceID] ?? 1.0
    }

    // MARK: - Initialization

    public init(sampleRate: Double = 48000, channels: UInt32 = 2) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    // MARK: - Public API

    /// Feed a sample from a source into the mixer
    /// - Parameters:
    ///   - sampleBuffer: Audio sample buffer (expected: PCM, target sample rate)
    ///   - sourceID: Identifier of the source
    public func addSample(_ sampleBuffer: CMSampleBuffer, from sourceID: String) {
        lock.lock()
        sourceBuffers[sourceID] = sampleBuffer
        activeSourceIDs.insert(sourceID)
        let sources = sourceBuffers
        lock.unlock()

        // If only one source, apply gain and pass through (most common case)
        if sources.count == 1 {
            gainLock.lock()
            let vol = sourceGains[sourceID] ?? 1.0
            gainLock.unlock()
            if vol >= 0.99 {
                // Full volume - zero-copy passthrough
                onMixedSample?(sampleBuffer)
            } else if let scaled = applyGain(vol, to: sampleBuffer) {
                onMixedSample?(scaled)
            }
            return
        }

        // Mix all current source buffers
        if let mixed = mixBuffers(sources) {
            onMixedSample?(mixed)
        }
    }

    /// Mark a source as inactive (e.g., TTS finished speaking)
    public func deactivateSource(_ sourceID: String) {
        lock.lock()
        activeSourceIDs.remove(sourceID)
        sourceBuffers.removeValue(forKey: sourceID)
        lock.unlock()
    }

    /// Remove all sources
    public func reset() {
        lock.lock()
        sourceBuffers.removeAll()
        activeSourceIDs.removeAll()
        lock.unlock()
    }

    // MARK: - Mixing

    /// Apply a gain factor to a single-source sample buffer
    private func applyGain(_ gain: Float, to sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let srcBlock = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        let bytesPerSample = Int(channels) * MemoryLayout<Int16>.size
        let dataLength = frameCount * bytesPerSample

        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard let outBlock = blockBuffer else { return nil }

        var srcPtr: UnsafeMutablePointer<Int8>?
        var srcLength = 0
        CMBlockBufferGetDataPointer(srcBlock, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &srcLength, dataPointerOut: &srcPtr)
        guard let srcData = srcPtr else { return nil }

        var outPtr: UnsafeMutablePointer<Int8>?
        var outLength = 0
        CMBlockBufferGetDataPointer(outBlock, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &outLength, dataPointerOut: &outPtr)
        guard let outData = outPtr else { return nil }

        let sampleCount = min(srcLength, dataLength) / MemoryLayout<Int16>.size
        srcData.withMemoryRebound(to: Int16.self, capacity: sampleCount) { src in
            outData.withMemoryRebound(to: Int16.self, capacity: sampleCount) { dst in
                for i in 0..<sampleCount {
                    let scaled = Float(src[i]) * gain
                    dst[i] = Int16(max(-32768, min(32767, scaled)))
                }
            }
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var result: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: outBlock,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &result
        )
        return result
    }

    private func mixBuffers(_ sources: [String: CMSampleBuffer]) -> CMSampleBuffer? {
        guard !sources.isEmpty else { return nil }

        // Use the first buffer as the template for format and timing
        guard let (_, templateBuffer) = sources.first else { return nil }

        guard let formatDesc = CMSampleBufferGetFormatDescription(templateBuffer) else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(templateBuffer)
        guard frameCount > 0 else { return nil }

        // Check if TTS is active for ducking
        let ttsActive = activeSourceIDs.contains("muse-tts")

        // Allocate output buffer
        let bytesPerSample = Int(channels) * MemoryLayout<Int16>.size
        let dataLength = frameCount * bytesPerSample

        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard let outBlock = blockBuffer else { return nil }

        // Zero the output buffer
        var zeroData = [UInt8](repeating: 0, count: dataLength)
        CMBlockBufferReplaceDataBytes(
            with: &zeroData,
            blockBuffer: outBlock,
            offsetIntoDestination: 0,
            dataLength: dataLength
        )

        // Get output data pointer
        var outputPtr: UnsafeMutablePointer<Int8>?
        var outputLength = 0
        CMBlockBufferGetDataPointer(
            outBlock,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &outputLength,
            dataPointerOut: &outputPtr
        )

        guard let outData = outputPtr else { return nil }
        let outputSamples = outData.withMemoryRebound(
            to: Int16.self,
            capacity: frameCount * Int(channels)
        ) { $0 }

        // Snapshot per-source gains
        gainLock.lock()
        let gains = sourceGains
        gainLock.unlock()

        // Mix each source into the output
        for (sourceID, buffer) in sources {
            guard let srcBlock = CMSampleBufferGetDataBuffer(buffer) else { continue }

            var srcPtr: UnsafeMutablePointer<Int8>?
            var srcLength = 0
            CMBlockBufferGetDataPointer(
                srcBlock,
                atOffset: 0,
                lengthAtOffsetOut: nil,
                totalLengthOut: &srcLength,
                dataPointerOut: &srcPtr
            )

            guard let srcData = srcPtr else { continue }
            let srcSamples = srcData.withMemoryRebound(
                to: Int16.self,
                capacity: min(srcLength / MemoryLayout<Int16>.size, frameCount * Int(channels))
            ) { $0 }

            let sampleCount = min(
                srcLength / MemoryLayout<Int16>.size,
                frameCount * Int(channels)
            )

            // Apply per-source volume gain (default 1.0) and TTS ducking
            let volumeGain = gains[sourceID] ?? 1.0
            let duckGain: Float = (ttsActive && sourceID != "muse-tts") ? ttsActiveDuckAmount : 1.0
            let totalGain = volumeGain * duckGain

            for i in 0..<sampleCount {
                let srcValue = Float(srcSamples[i]) * totalGain
                let currentValue = Float(outputSamples[i])
                let mixed = currentValue + srcValue

                // Clip to Int16 range
                outputSamples[i] = Int16(max(-32768, min(32767, mixed)))
            }
        }

        // Create output sample buffer
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(templateBuffer)

        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: outBlock,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }
}
