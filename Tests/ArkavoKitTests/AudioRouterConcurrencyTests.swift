import Testing
import AVFoundation
import CoreMedia
@testable import ArkavoRecorder

/// Each audio source delivers on its own capture queue, so the router is called from
/// several threads at once. Run with `swift test --sanitize=thread` to check for races.
struct AudioRouterConcurrencyTests {
    @Test("Two sources delivering at the same time are both routed")
    func sourcesDeliverConcurrently() {
        let router = AudioRouter()
        let sources = [FakeAudioSource(sourceID: "microphone"), FakeAudioSource(sourceID: "screen")]
        for source in sources { router.addSource(source) }
        let routed = Counter()
        router.onConvertedSample = { _, _ in routed.increment() }

        let perSource = 200
        DispatchQueue.concurrentPerform(iterations: sources.count) { index in
            for i in 0..<perSource {
                let pts = CMTime(value: CMTimeValue(i * 960), timescale: 48000)
                sources[index].onSample?(AudioMixerTests.buffer(frames: 960, value: 1000, pts: pts))
            }
        }

        #expect(routed.value == sources.count * perSource)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }
}
