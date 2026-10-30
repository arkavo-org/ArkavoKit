#if os(macOS)
import Testing
import ScreenCaptureKit
@testable import ArkavoRecorder

/// Desktop audio must not capture the host app's own output: sources the app mixes directly
/// (Muse's voice) would otherwise reach the mix twice, the second copy delayed (Creator#127).
struct ScreenAudioConfigurationTests {
    @Test("Desktop audio excludes the host app's own audio and captures 48 kHz stereo")
    func excludesCurrentProcessAudio() {
        let config = ScreenAudioSource.makeStreamConfiguration()
        #expect(config.capturesAudio)
        #expect(config.excludesCurrentProcessAudio)
        #expect(config.sampleRate == 48000)
        #expect(config.channelCount == 2)
    }
}
#endif
