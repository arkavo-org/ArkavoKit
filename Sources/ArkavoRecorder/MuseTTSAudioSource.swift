//
//  MuseTTSAudioSource.swift
//  ArkavoKit
//
//  Captures AVSpeechSynthesizer TTS audio as CMSampleBuffer for streaming.
//  Renders TTS to buffers (not speakers) and emits via AudioSource protocol.
//

import AVFoundation
import CoreMedia

/// Audio source that captures TTS speech output for streaming
/// Uses AVSpeechSynthesizer's write() API to render audio to buffers
public final class MuseTTSAudioSource: NSObject, AudioSource, @unchecked Sendable {
    // MARK: - AudioSource Protocol

    public let sourceID: String
    public let sourceName: String = "Muse TTS"

    public var format: AudioFormat {
        AudioFormat(
            sampleRate: 48000,
            channels: 1,
            bitDepth: 16,
            formatID: kAudioFormatLinearPCM
        )
    }

    public private(set) var isActive: Bool = false
    public var onSample: ((CMSampleBuffer) -> Void)?

    // MARK: - Properties

    private let synthesizer = AVSpeechSynthesizer()
    private var pendingUtterances: [AVSpeechUtterance] = []

    /// Speech rate (matches AVSpeechUtterance rate scale)
    public var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate

    /// Voice identifier (nil = system default)
    public var voiceIdentifier: String?

    /// Called when an utterance finishes speaking
    public var onUtteranceFinished: (() -> Void)?

    // MARK: - Initialization

    public init(sourceID: String = "muse-tts") {
        self.sourceID = sourceID
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - AudioSource Protocol

    public func start() async throws {
        isActive = true
    }

    public func stop() async throws {
        isActive = false
        synthesizer.stopSpeaking(at: .immediate)
        pendingUtterances.removeAll()
    }

    // MARK: - TTS API

    /// Speak text and capture audio as CMSampleBuffers
    /// Audio is rendered to buffers, not played through speakers
    public func speak(_ text: String) {
        guard isActive else { return }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = speechRate

        if let voiceID = voiceIdentifier,
           let voice = AVSpeechSynthesisVoice(identifier: voiceID)
        {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        // Use write() to render audio to buffers instead of playing
        synthesizer.write(utterance) { [weak self] buffer in
            guard let self, self.isActive else { return }

            guard let pcmBuffer = buffer as? AVAudioPCMBuffer,
                  pcmBuffer.frameLength > 0
            else { return }

            // Convert AVAudioPCMBuffer to CMSampleBuffer
            if let sampleBuffer = self.convertToSampleBuffer(pcmBuffer) {
                self.onSample?(sampleBuffer)
            }
        }
    }

    /// Stop current speech immediately
    public func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Check if currently speaking
    public var isSpeaking: Bool {
        synthesizer.isSpeaking
    }

    // MARK: - Private

    /// Running sample count for timestamp calculation
    private var totalSamplesWritten: Int64 = 0

    private func convertToSampleBuffer(_ pcmBuffer: AVAudioPCMBuffer) -> CMSampleBuffer? {
        let format = pcmBuffer.format
        let frameCount = CMItemCount(pcmBuffer.frameLength)

        // Create format description
        var formatDescription: CMAudioFormatDescription?
        let asbd = format.streamDescription.pointee
        var asbdCopy = asbd
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbdCopy,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let desc = formatDescription else {
            return nil
        }

        // Create timing info using running sample count
        let sampleRate = asbd.mSampleRate
        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(
                value: totalSamplesWritten,
                timescale: CMTimeScale(sampleRate)
            ),
            decodeTimeStamp: .invalid
        )

        totalSamplesWritten += Int64(frameCount)

        // Create sample buffer from audio buffer list
        var sampleBuffer: CMSampleBuffer?
        guard let audioBufferList = pcmBuffer.audioBufferList.pointee.mBuffers.mData else {
            return nil
        }

        let dataLength = Int(pcmBuffer.audioBufferList.pointee.mBuffers.mDataByteSize)
        let blockBuffer: CMBlockBuffer?
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &block
        )

        guard let blk = block else { return nil }
        blockBuffer = blk

        CMBlockBufferReplaceDataBytes(
            with: audioBufferList,
            blockBuffer: blk,
            offsetIntoDestination: 0,
            dataLength: dataLength
        )

        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer!,
            formatDescription: desc,
            sampleCount: frameCount,
            presentationTimeStamp: timing.presentationTimeStamp,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension MuseTTSAudioSource: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(
        _: AVSpeechSynthesizer,
        didFinish _: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.onUtteranceFinished?()
        }
    }
}
