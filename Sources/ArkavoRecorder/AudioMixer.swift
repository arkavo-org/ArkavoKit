//
//  AudioMixer.swift
//  ArkavoKit
//
//  Mixes multiple audio CMSampleBuffer streams into a single output.
//  Clock-driven FIFO: one source (the first to deliver, or `clockSourceID`)
//  sets the frame cadence; every other source is a FIFO of samples drained
//  by the clock's frame length and zero-filled when short. A configured voice
//  source ducks the others while it has audio queued. The voice is never
//  auto-picked as the clock while other sources are registered, and every FIFO
//  is capped at `maxQueuedSeconds` (oldest samples dropped).
//

import AVFoundation
import CoreMedia

public final class AudioMixer: @unchecked Sendable {
    private let sampleRate: Double
    private let channels: UInt32

    private let lock = NSLock()
    private var fifos: [String: [Int16]] = [:]        // interleaved Int16, non-clock sources only
    private var clockSourceID: String?
    private var registeredSourceIDs: Set<String> = []
    private var sourceGains: [String: Float] = [:]
    private var lastVoiceActivity: TimeInterval = -.infinity

    /// The source whose activity ducks the others (the Muse voice). nil = no ducking.
    public let voiceSourceID: String?
    /// Attenuation applied to non-voice sources while the voice is active (0.7 = 70%).
    public var voiceDuckAmount: Float = 0.7
    /// How long after the voice FIFO empties the duck stays applied, in seconds.
    public var voiceDuckHangover: TimeInterval = 0.3

    /// Longest a non-clock source may queue, in seconds. Older samples are dropped.
    public let maxQueuedSeconds: Double = 0.2

    public var onMixedSample: ((CMSampleBuffer) -> Void)?

    public init(sampleRate: Double = 48000, channels: UInt32 = 2, voiceSourceID: String? = nil) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.voiceSourceID = voiceSourceID
    }

    /// Pins the clock source. Otherwise the first source to deliver becomes the clock.
    /// Drops any audio the new clock had queued as a non-clock source.
    public func setClockSource(_ sourceID: String?) {
        lock.lock()
        clockSourceID = sourceID
        if let sourceID { fifos.removeValue(forKey: sourceID) }
        lock.unlock()
    }

    /// Declares a source that exists but may not have delivered yet. While any
    /// non-voice source is registered, the voice is never auto-picked as the clock.
    /// Registrations survive `reset()` (they mirror the router, not the session).
    public func registerSource(_ sourceID: String) {
        lock.lock(); registeredSourceIDs.insert(sourceID); lock.unlock()
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
        if clockSourceID == nil {
            let isVoice = sourceID == voiceSourceID
            let othersExist = !registeredSourceIDs.subtracting([sourceID]).isEmpty
            // The voice is intermittent: it only becomes the clock when nothing else could be.
            if !(isVoice && othersExist) { clockSourceID = sourceID }
        }
        let isClock = clockSourceID == sourceID
        if sourceID == voiceSourceID { lastVoiceActivity = CACurrentMediaTime() }
        if !isClock {
            let cap = Int(sampleRate * Double(channels) * maxQueuedSeconds)
            var fifo = fifos[sourceID] ?? []
            fifos[sourceID] = nil   // keep `fifo` uniquely referenced so removeFirst is in place
            fifo.append(contentsOf: incoming)
            if fifo.count > cap { fifo.removeFirst(fifo.count - cap) }
            fifos[sourceID] = fifo
            lock.unlock()
            return
        }
        // Drain every other FIFO by the clock's frame count.
        let frameSamples = incoming.count
        var contributions: [(id: String, samples: [Int16])] = []
        for id in Array(fifos.keys) where id != clockSourceID {
            guard var fifo = fifos[id] else { continue }
            fifos[id] = nil
            let take = min(frameSamples, fifo.count)
            contributions.append((id, Array(fifo.prefix(take))))
            fifo.removeFirst(take)
            fifos[id] = fifo
        }
        let voiceQueued = voiceSourceID.map { (fifos[$0]?.isEmpty == false) } ?? false
        let voiceRecent = CACurrentMediaTime() - lastVoiceActivity <= voiceDuckHangover
        let ducking = voiceSourceID != nil && (voiceQueued || voiceRecent || contributions.contains { $0.id == voiceSourceID && !$0.samples.isEmpty })
        let gains = sourceGains
        lock.unlock()

        var mixed = [Float](repeating: 0, count: frameSamples)
        func add(_ id: String, _ src: [Int16]) {
            let duck: Float = (ducking && id != voiceSourceID) ? voiceDuckAmount : 1.0
            let g = (gains[id] ?? 1.0) * duck
            for (i, v) in src.enumerated() { mixed[i] += Float(v) * g }
        }
        add(sourceID, incoming)
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
