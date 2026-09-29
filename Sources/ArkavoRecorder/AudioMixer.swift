//
//  AudioMixer.swift
//  ArkavoKit
//
//  Mixes multiple audio CMSampleBuffer streams into a single output.
//  Clock-driven FIFO: one source (the first to deliver, or `clockSourceID`)
//  sets the frame cadence; every other source is a FIFO of samples drained
//  by the clock's frame length and zero-filled when short. A configured voice
//  source ducks the others while it has audio queued.
//

import AVFoundation
import CoreMedia

public final class AudioMixer: @unchecked Sendable {
    private let sampleRate: Double
    private let channels: UInt32

    private let lock = NSLock()
    private var fifos: [String: [Int16]] = [:]        // interleaved Int16, non-clock sources only
    private var clockSourceID: String?
    private var sourceGains: [String: Float] = [:]
    private var lastVoiceActivity: TimeInterval = -.infinity

    /// The source whose activity ducks the others (the Muse voice). nil = no ducking.
    public let voiceSourceID: String?
    /// Attenuation applied to non-voice sources while the voice is active (0.7 = 70%).
    public var voiceDuckAmount: Float = 0.7
    /// How long after the voice FIFO empties the duck stays applied, in seconds.
    public var voiceDuckHangover: TimeInterval = 0.3

    public var onMixedSample: ((CMSampleBuffer) -> Void)?

    public init(sampleRate: Double = 48000, channels: UInt32 = 2, voiceSourceID: String? = nil) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.voiceSourceID = voiceSourceID
    }

    /// Pins the clock source. Otherwise the first source to deliver becomes the clock.
    public func setClockSource(_ sourceID: String?) {
        lock.lock(); clockSourceID = sourceID; lock.unlock()
    }

    public func setGain(_ gain: Float, for sourceID: String) {
        lock.lock(); sourceGains[sourceID] = max(0, min(1, gain)); lock.unlock()
    }

    public func gain(for sourceID: String) -> Float {
        lock.lock(); defer { lock.unlock() }
        return sourceGains[sourceID] ?? 1.0
    }

    public func addSample(_ sampleBuffer: CMSampleBuffer, from sourceID: String) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let incoming = Self.samples(of: sampleBuffer)
        guard !incoming.isEmpty else { return }

        lock.lock()
        if clockSourceID == nil { clockSourceID = sourceID }
        let isClock = clockSourceID == sourceID
        if sourceID == voiceSourceID { lastVoiceActivity = CACurrentMediaTime() }
        if !isClock {
            fifos[sourceID, default: []].append(contentsOf: incoming)
            lock.unlock()
            return
        }
        // Drain every other FIFO by the clock's frame count.
        let frameSamples = incoming.count
        var contributions: [(id: String, samples: ArraySlice<Int16>)] = []
        for (id, fifo) in fifos {
            let take = min(frameSamples, fifo.count)
            contributions.append((id, fifo[0..<take]))
            fifos[id] = Array(fifo[take...])
        }
        let voiceQueued = voiceSourceID.map { (fifos[$0]?.isEmpty == false) } ?? false
        let voiceRecent = CACurrentMediaTime() - lastVoiceActivity <= voiceDuckHangover
        let ducking = voiceSourceID != nil && (voiceQueued || voiceRecent || contributions.contains { $0.id == voiceSourceID && !$0.samples.isEmpty })
        let gains = sourceGains
        lock.unlock()

        var mixed = [Float](repeating: 0, count: frameSamples)
        func add(_ id: String, _ src: ArraySlice<Int16>) {
            let duck: Float = (ducking && id != voiceSourceID) ? voiceDuckAmount : 1.0
            let g = (gains[id] ?? 1.0) * duck
            for (i, v) in src.enumerated() { mixed[i] += Float(v) * g }
        }
        add(sourceID, incoming[...])
        for c in contributions { add(c.id, c.samples) }

        let out = mixed.map { Int16(max(-32768, min(32767, $0))) }
        if let sb = Self.makeBuffer(out, frames: frameSamples / Int(channels), format: formatDesc,
                                    pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) {
            onMixedSample?(sb)
        }
    }

    /// Drops a source's queued audio (e.g. the voice was cut).
    public func deactivateSource(_ sourceID: String) {
        lock.lock(); fifos.removeValue(forKey: sourceID); lock.unlock()
    }

    public func reset() {
        lock.lock(); fifos.removeAll(); clockSourceID = nil; lastVoiceActivity = -.infinity; lock.unlock()
    }

    // MARK: - Buffers

    private static func samples(of sb: CMSampleBuffer) -> [Int16] {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return [] }
        var length = 0
        var ptr: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
        guard let ptr, length >= 2 else { return [] }
        return ptr.withMemoryRebound(to: Int16.self, capacity: length / 2) {
            Array(UnsafeBufferPointer(start: $0, count: length / 2))
        }
    }

    private static func makeBuffer(_ samples: [Int16], frames: Int, format: CMFormatDescription, pts: CMTime) -> CMSampleBuffer? {
        let length = samples.count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                           blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                           dataLength: length, flags: 0, blockBufferOut: &block)
        guard let block else { return nil }
        var copy = samples
        copy.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        var out: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &out)
        return out
    }
}
