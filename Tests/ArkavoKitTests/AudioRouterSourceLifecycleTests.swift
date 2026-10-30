import Testing
import AVFoundation
import CoreMedia
@testable import ArkavoRecorder

/// A router owns its sources: one it no longer holds can't be stopped by anyone.
@MainActor
struct AudioRouterSourceLifecycleTests {
    @Test("Replacing a source detaches and stops the one it replaces")
    func replacingASourceStopsTheOldOne() async throws {
        let router = AudioRouter()
        let old = FakeAudioSource(sourceID: "microphone")
        router.addSource(old)
        try await router.startAll()
        #expect(old.isActive)

        router.addSource(FakeAudioSource(sourceID: "microphone"))

        #expect(old.onSample == nil, "the replaced source still feeds the router")
        let deadline = ContinuousClock.now + .seconds(2)
        while old.isActive && .now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!old.isActive, "the replaced source is still capturing")
    }

    @Test("Starting all sources leaves a source that is already running alone")
    func startAllSkipsRunningSources() async throws {
        let router = AudioRouter()
        let source = CountingAudioSource(sourceID: "screen")
        router.addSource(source)
        try await router.startAll()
        try await router.startAll()
        #expect(source.starts == 1)
    }

    @Test("A source that fails to start doesn't keep the one beside it from starting, and starting all still throws")
    nonisolated func failingSourceLetsTheOtherStart() async throws {
        // The router's order is unspecified. Each source fails in turn, in several routers kept
        // alive (so none reuses another's storage), so the failing one comes first in some of them.
        var routers: [AudioRouter] = []
        for (failingID, healthyID) in [("screen", "microphone"), ("microphone", "screen")] {
            for _ in 0..<5 {
                let router = AudioRouter()
                routers.append(router)
                let healthy = FakeAudioSource(sourceID: healthyID)
                router.addSource(FailingAudioSource(sourceID: failingID))
                router.addSource(healthy)

                await #expect(throws: RecorderError.screenCaptureUnavailable) { try await router.startAll() }
                #expect(healthy.isActive, "\(failingID) failing kept \(healthyID) from starting")
            }
        }
    }
}

/// Can't start, as screen audio without screen recording permission can't.
private final class FailingAudioSource: AudioSource {
    let sourceID: String
    let sourceName = "Failing"
    let format = AudioFormat(sampleRate: 48000, channels: 2, bitDepth: 16, formatID: kAudioFormatLinearPCM)
    let isActive = false
    var onSample: ((CMSampleBuffer) -> Void)?

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    func start() async throws {
        throw RecorderError.screenCaptureUnavailable
    }

    func stop() async throws {}
}

/// Counts its starts. Starting one that is running would open a second capture.
private final class CountingAudioSource: AudioSource {
    let sourceID: String
    let sourceName = "Counting"
    let format = AudioFormat(sampleRate: 48000, channels: 2, bitDepth: 16, formatID: kAudioFormatLinearPCM)
    private(set) var isActive = false
    private(set) var starts = 0
    var onSample: ((CMSampleBuffer) -> Void)?

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    func start() async throws {
        starts += 1
        isActive = true
    }

    func stop() async throws {
        isActive = false
    }
}
