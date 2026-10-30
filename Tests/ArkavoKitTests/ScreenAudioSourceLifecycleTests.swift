#if os(macOS)
import Testing
import CoreMedia
import os
@testable import ArkavoRecorder

/// Desktop audio can stop by itself: the user ends sharing, displays change, the capture service
/// restarts. A source that kept reading as running would be reused and never started again, and
/// recordings would silently lose desktop audio.
@MainActor
struct ScreenAudioSourceLifecycleTests {
    @Test("A desktop audio capture that stops by itself leaves the source stopped, and the next start opens a fresh one")
    func captureStoppingByItselfLetsTheNextStartReopen() async throws {
        let captures = StandInCaptures()
        let source = ScreenAudioSource(sourceID: "screen", openCapture: captures.open)
        let router = AudioRouter()
        router.addSource(source)
        try await router.startAll()
        #expect(source.isActive)

        captures.opened[0].stopByItself()

        #expect(!source.isActive)
        try await router.startAll()
        #expect(captures.opened.count == 2)
        #expect(source.isActive)
    }

    @Test("Stopping a desktop audio capture that fails to stop still leaves the source stopped")
    func failedStopStillStopsTheSource() async throws {
        let captures = StandInCaptures()
        let source = ScreenAudioSource(sourceID: "screen", openCapture: captures.open)
        let router = AudioRouter()
        router.addSource(source)
        try await router.startAll()
        captures.opened[0].stopFails = true

        try? await router.stopAll()

        #expect(!source.isActive)
        try await router.startAll()
        #expect(captures.opened.count == 2)
        #expect(source.isActive)
    }

    @Test("A capture replaced by a newer one can't stop the newer one by stopping late")
    func lateStopOfAReplacedCaptureIsIgnored() async throws {
        let captures = StandInCaptures()
        let source = ScreenAudioSource(sourceID: "screen", openCapture: captures.open)
        try await source.start()
        try await source.stop()
        try await source.start()

        captures.opened[0].stopByItself()

        #expect(source.isActive)
    }
}

/// Stand-ins for ScreenCaptureKit captures, kept in the order they were opened.
@MainActor
private final class StandInCaptures {
    private(set) var opened: [StandInCapture] = []

    var open: OpenScreenAudioCapture {
        { [self] _, onStop in
            let capture = StandInCapture(onStop: onStop)
            await MainActor.run { opened.append(capture) }
            return capture
        }
    }
}

private final class StandInCapture: ScreenAudioCapture, @unchecked Sendable {
    private let onStop: (any Error) -> Void
    private let state = OSAllocatedUnfairLock(initialState: false)

    init(onStop: @escaping (any Error) -> Void) {
        self.onStop = onStop
    }

    /// `stop()` throws, as it does for a stream that has already stopped.
    var stopFails: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    func stop() async throws {
        if stopFails { throw RecorderError.screenCaptureUnavailable }
    }

    /// The stream stops without being asked, as when the user ends sharing.
    func stopByItself() {
        onStop(RecorderError.screenCaptureUnavailable)
    }
}
#endif
