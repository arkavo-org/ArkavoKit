//
//  AudioMixer.swift
//  ArkavoKit
//
//  Mixes multiple audio CMSampleBuffer streams into a single output.
//  Clock-driven FIFO: one source (the first to deliver, or `clockSourceID`)
//  sets the frame cadence; every other source is a FIFO of samples drained
//  by the clock's frame length. A FIFO is a jitter buffer: it starts playing
//  only once it holds `prefillSeconds` of audio or its oldest sample has waited
//  that long in clock frames, so a producer whose chunks don't line up with the
//  clock's buffers isn't zero-filled mid-stream; it is zero-filled only when it
//  runs dry, and then builds its lead again. A configured voice source ducks the
//  others while it has audio queued. The voice is never auto-picked as the clock
//  while other sources are registered, and every FIFO is capped at
//  `maxQueuedSeconds` (oldest samples dropped).
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
    /// Non-clock sources whose FIFO has built its lead and is being drained.
    private var primed: Set<String> = []
    /// Clock frames drained since an unprimed source's oldest queued sample arrived.
    private var framesWaited: [String: Int] = [:]

    /// The source whose activity ducks the others (the Muse voice). nil = no ducking.
    public let voiceSourceID: String?
    /// Attenuation applied to non-voice sources while the voice is active (0.7 = 70%).
    public var voiceDuckAmount: Float = 0.7
    /// How long after the voice FIFO empties the duck stays applied, in seconds.
    public var voiceDuckHangover: TimeInterval = 0.3

    /// Longest a non-clock source may queue, in seconds. Older samples are dropped.
    public let maxQueuedSeconds: Double = AudioMixer.queueCapSeconds
    private static let queueCapSeconds = 0.2

    /// Default lead a non-clock source builds before it plays: about two 20 ms voice chunks.
    public static let defaultPrefillSeconds = 0.04

    /// Lead, in seconds, a non-clock source builds before it plays, and how long (in clock
    /// frames) a shorter sound waits before playing anyway. It delays every non-clock source
    /// by about this much relative to the clock. At most half of `maxQueuedSeconds`, so a
    /// source that has built its lead keeps headroom below the cap and is never trimmed.
    public let prefillSeconds: Double

    /// The source ID the mix reaches the encoder under.
    public static let outputSourceID = "mixed"

    public var onMixedSample: ((CMSampleBuffer) -> Void)?

    public init(
        sampleRate: Double = 48000,
        channels: UInt32 = 2,
        voiceSourceID: String? = nil,
        prefillSeconds: Double = AudioMixer.defaultPrefillSeconds
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.voiceSourceID = voiceSourceID
        self.prefillSeconds = min(max(0, prefillSeconds), Self.queueCapSeconds / 2)
    }

    /// Pins the clock source. Otherwise the first source to deliver becomes the clock.
    /// Drops any audio the new clock had queued as a non-clock source.
    public func setClockSource(_ sourceID: String?) {
        lock.lock()
        clockSourceID = sourceID
        if let sourceID { dropQueue(of: sourceID) }
        lock.unlock()
    }

    /// Declares a source that exists but may not have delivered yet. While any
    /// non-voice source is registered, the voice is never auto-picked as the clock.
    /// Registrations survive `reset()` (they mirror the router, not the session).
    public func registerSource(_ sourceID: String) {
        lock.lock(); registeredSourceIDs.insert(sourceID); lock.unlock()
    }

    /// Forgets a source the router removed, with its queued audio, so it no longer
    /// keeps the voice from becoming the clock.
    func unregisterSource(_ sourceID: String) {
        lock.lock()
        registeredSourceIDs.remove(sourceID)
        dropQueue(of: sourceID)
        if clockSourceID == sourceID { clockSourceID = nil }
        lock.unlock()
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
        // Drain every other FIFO by the clock's frame count, once it has built its lead.
        let frameSamples = incoming.count
        let clockFrames = frameSamples / Int(channels)
        let prefillFrames = Int((sampleRate * prefillSeconds).rounded())
        let prefillSamples = prefillFrames * Int(channels)
        var contributions: [(id: String, samples: [Int16])] = []
        for id in Array(fifos.keys) where id != clockSourceID {
            guard var fifo = fifos[id] else { continue }
            if !primed.contains(id) {
                guard !fifo.isEmpty else { continue }
                // Wait for a full lead, or for a sound shorter than one to have waited as long.
                let waited = (framesWaited[id] ?? 0) + clockFrames
                guard fifo.count >= prefillSamples || waited >= prefillFrames else {
                    framesWaited[id] = waited
                    continue
                }
                primed.insert(id)
                framesWaited[id] = nil
            }
            fifos[id] = nil
            let take = min(frameSamples, fifo.count)
            // Short of a full buffer, the source has run dry: the rest is silence, and its next
            // audio builds a fresh lead rather than playing with a hole every few buffers.
            if take < frameSamples { primed.remove(id) }
            if take > 0 {
                contributions.append((id, Array(fifo.prefix(take))))
                fifo.removeFirst(take)
            }
            fifos[id] = fifo
        }
        // Queued voice ducks even while it builds its lead, so the duck starts up to one prefill
        // before the voice is audible and its first syllable never lands on unducked audio.
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
        lock.lock(); dropQueue(of: sourceID); lock.unlock()
    }

    public func reset() {
        lock.lock()
        fifos.removeAll()
        primed.removeAll()
        framesWaited.removeAll()
        clockSourceID = nil
        lastVoiceActivity = -.infinity
        lock.unlock()
    }

    /// Drops a source's queued audio and its lead, so its next audio builds a fresh one.
    /// Call with `lock` held.
    private func dropQueue(of sourceID: String) {
        fifos.removeValue(forKey: sourceID)
        primed.remove(sourceID)
        framesWaited.removeValue(forKey: sourceID)
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
