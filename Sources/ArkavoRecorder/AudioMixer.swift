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

    /// Ducking: reduce other sources when a priority source is active
    /// Key = source ID that triggers ducking, value = attenuation factor (0-1)
    public var duckingRules: [String: Float] = [:]

    /// Default ducking amount when Muse TTS is speaking (0.7 = reduce mic to 70%)
    public var ttsActiveDuckAmount: Float = 0.7

    /// Callback for mixed output
    public var onMixedSample: ((CMSampleBuffer) -> Void)?

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

        // If only one source, pass through directly (most common case)
        if sources.count == 1 {
            onMixedSample?(sampleBuffer)
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

            // Apply ducking if TTS is active and this isn't the TTS source
            let gain: Float = (ttsActive && sourceID != "muse-tts") ? ttsActiveDuckAmount : 1.0

            for i in 0..<sampleCount {
                let srcValue = Float(srcSamples[i]) * gain
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
