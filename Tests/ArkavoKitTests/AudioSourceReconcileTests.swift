import Testing
import AVFoundation
import CoreMedia
@testable import ArkavoRecorder

/// A session is reused across recordings, so the microphone and screen audio must follow
/// the current settings at each start, not stay from an earlier recording.
@MainActor
struct AudioSourceReconcileTests {
    @Test("The microphone and screen audio are unwanted when their settings are off; other sources are left alone")
    func unwantedSourcesFollowTheSettings() {
        let all = ["microphone", "screen", "muse-voice"]
        #expect(Set(RecordingSession.unwantedAudioSourceIDs(in: all, microphone: false, screenAudio: false)) == ["microphone", "screen"])
        #expect(RecordingSession.unwantedAudioSourceIDs(in: all, microphone: true, screenAudio: false) == ["screen"])
        #expect(RecordingSession.unwantedAudioSourceIDs(in: all, microphone: false, screenAudio: true) == ["microphone"])
        #expect(RecordingSession.unwantedAudioSourceIDs(in: all, microphone: true, screenAudio: true) == [])
        #expect(RecordingSession.unwantedAudioSourceIDs(in: ["muse-voice"], microphone: false, screenAudio: false) == [])
    }

    @Test("A recording with the microphone off stops and drops a microphone left from an earlier recording")
    func startDropsAMicrophoneTheSettingsTurnedOff() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconcile-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try RecordingSession()
        // Stand-ins for the microphone an earlier recording added, and the Muse voice
        let staleMicrophone = FakeAudioSource(sourceID: "microphone")
        let voice = FakeAudioSource(sourceID: "muse-voice")
        session.addMuseAudioSource(staleMicrophone)
        session.addMuseAudioSource(voice)

        // Avatar mode with no avatar frames needs no permissions
        session.enableDesktop = false
        session.enableCamera = false
        session.enableMicrophone = false
        session.enableScreenAudio = false
        session.enableAvatar = true
        try await session.startRecording(outputURL: url, title: "microphone off")

        #expect(session.registeredAudioSourceIDs == ["muse-voice"])
        #expect(!staleMicrophone.started, "the disabled microphone must not capture")
        #expect(voice.started)
        _ = try? await session.stopRecording()
    }
}

final class FakeAudioSource: AudioSource {
    let sourceID: String
    let sourceName = "Fake"
    let format = AudioFormat(sampleRate: 48000, channels: 2, bitDepth: 16, formatID: kAudioFormatLinearPCM)
    var isActive = false
    var onSample: ((CMSampleBuffer) -> Void)?
    private(set) var started = false

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    func start() async throws {
        started = true
        isActive = true
    }

    func stop() async throws {
        isActive = false
    }
}
