//
//  MuseTTSAudioSource.swift
//  ArkavoKit
//
//  Captures AVSpeechSynthesizer TTS audio as CMSampleBuffer for streaming.
//  Renders TTS to buffers (not speakers) and emits via AudioSource protocol.
//

import AVFoundation
import CoreMedia
import os

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

    public var isActive: Bool {
        state.withLockUnchecked { $0.isActive }
    }

    public var onSample: ((CMSampleBuffer) -> Void)? {
        get { state.withLockUnchecked { $0.onSample } }
        set { state.withLockUnchecked { $0.onSample = newValue } }
    }

    // MARK: - Properties

    private struct SharedState {
        var isActive: Bool = false
        var onSample: ((CMSampleBuffer) -> Void)?
        var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate
        var voiceIdentifier: String?
        var onUtteranceFinished: (() -> Void)?
        var anchorHostTime: CMTime?
        var samplesSinceAnchor: Int64 = 0
        var lastSampleRate: Double = 0
    }

    private let state = OSAllocatedUnfairLock<SharedState>(uncheckedState: SharedState())
    private let synthesizer = AVSpeechSynthesizer()

    /// Speech rate (matches AVSpeechUtterance rate scale)
    public var speechRate: Float {
        get { state.withLockUnchecked { $0.speechRate } }
        set { state.withLockUnchecked { $0.speechRate = newValue } }
    }

    /// Voice identifier (nil = system default)
    public var voiceIdentifier: String? {
        get { state.withLockUnchecked { $0.voiceIdentifier } }
        set { state.withLockUnchecked { $0.voiceIdentifier = newValue } }
    }

    /// Called when an utterance finishes speaking
    public var onUtteranceFinished: (() -> Void)? {
        get { state.withLockUnchecked { $0.onUtteranceFinished } }
        set { state.withLockUnchecked { $0.onUtteranceFinished = newValue } }
    }

    // MARK: - Initialization

    public init(sourceID: String = "muse-voice") {
        self.sourceID = sourceID
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - AudioSource Protocol

    public func start() async throws {
        state.withLockUnchecked { state in
            state.isActive = true
            state.anchorHostTime = nil
            state.samplesSinceAnchor = 0
            state.lastSampleRate = 0
        }
    }

    public func stop() async throws {
        state.withLockUnchecked { state in
            state.isActive = false
            state.anchorHostTime = nil
            state.samplesSinceAnchor = 0
            state.lastSampleRate = 0
        }
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - TTS API

    /// Speak text and capture audio as CMSampleBuffers
    /// Audio is rendered to buffers, not played through speakers
    public func speak(_ text: String) {
        let (active, rate, voiceID) = state.withLockUnchecked { state in
            (state.isActive, state.speechRate, state.voiceIdentifier)
        }
        guard active else { return }

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate

        if let voiceID,
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
                let callback = self.state.withLockUnchecked { $0.onSample }
                callback?(sampleBuffer)
            }
        }
    }

    /// Stop current speech immediately
    public func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        state.withLockUnchecked { state in
            state.anchorHostTime = nil
            state.samplesSinceAnchor = 0
        }
    }

    /// Check if currently speaking
    public var isSpeaking: Bool {
        synthesizer.isSpeaking
    }

    // MARK: - Internal / Private

    func convertToSampleBuffer(_ pcmBuffer: AVAudioPCMBuffer) -> CMSampleBuffer? {
        let frameCount = CMItemCount(pcmBuffer.frameLength)
        guard frameCount > 0 else { return nil }

        let format = pcmBuffer.format
        var asbdCopy = format.streamDescription.pointee
        let sampleRate = asbdCopy.mSampleRate
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        let timescale = CMTimeScale(sampleRate.rounded())
        guard timescale > 0 else { return nil }

        // Create format description
        var formatDescription: CMAudioFormatDescription?
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

        // Anchor PTS to the host clock and advance continuously by sample count so TTS-only
        // video recordings align with host-clock video frames rather than being dropped as beforeStart.
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let presentationTimeStamp: CMTime = state.withLockUnchecked { state in
            let pts: CMTime
            if let anchor = state.anchorHostTime, state.lastSampleRate == sampleRate {
                let offset = CMTime(value: state.samplesSinceAnchor, timescale: timescale)
                let continuous = CMTimeAdd(anchor, offset)
                // Re-anchor after pauses between utterances so new speech aligns with current video.
                if CMTimeSubtract(now, continuous).seconds > 0.25 {
                    let reanchored = CMTimeConvertScale(now, timescale: timescale, method: .default)
                    state.anchorHostTime = reanchored
                    state.samplesSinceAnchor = 0
                    pts = reanchored
                } else {
                    pts = continuous
                }
            } else {
                let anchored = CMTimeConvertScale(now, timescale: timescale, method: .default)
                state.anchorHostTime = anchored
                state.samplesSinceAnchor = 0
                state.lastSampleRate = sampleRate
                pts = anchored
            }
            state.samplesSinceAnchor += Int64(frameCount)
            return pts
        }

        // Create sample buffer and copy ALL channels/planes from the full AudioBufferList.
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: desc,
            sampleCount: frameCount,
            presentationTimeStamp: presentationTimeStamp,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let buffer = sampleBuffer else {
            return nil
        }

        let dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcmBuffer.audioBufferList
        )
        guard dataStatus == noErr else {
            return nil
        }

        return buffer
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension MuseTTSAudioSource: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(
        _: AVSpeechSynthesizer,
        didFinish _: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let callback = self.state.withLockUnchecked { $0.onUtteranceFinished }
            callback?()
        }
    }
}
