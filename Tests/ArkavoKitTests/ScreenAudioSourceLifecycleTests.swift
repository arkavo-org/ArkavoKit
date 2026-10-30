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

    // Two starts can overlap: a stream's audio starting while a recording starts its own.

    @Test("Two starts that overlap open one desktop audio capture, and stopping the source stops it")
    func overlappingStartsOpenOneCapture() async throws {
        let captures = StandInCaptures(held: true)
        let source = ScreenAudioSource(sourceID: "screen", openCapture: captures.open)
        let first = Task { try await source.start() }
        try await Self.waitUntil { captures.opened.count == 1 }
        let second = Task { try await source.start() }
        try await Task.sleep(for: .milliseconds(200))   // time for a second open to begin

        captures.release()
        try await first.value
        try await second.value

        #expect(captures.opened.count == 1)
        #expect(source.isActive)
        try await source.stop()
        #expect(captures.opened.allSatisfy { $0.isStopped }, "a capture is still open")
    }

    @Test("A stop while the source is starting leaves no desktop audio capture open")
    func stopDuringAStartLeavesNoCaptureOpen() async throws {
        let captures = StandInCaptures(held: true)
        let source = ScreenAudioSource(sourceID: "screen", openCapture: captures.open)
        let start = Task { try await source.start() }
        try await Self.waitUntil { captures.opened.count == 1 }

        try await source.stop()
        captures.release()
        try await start.value

        #expect(!source.isActive)
        #expect(captures.opened.allSatisfy { $0.isStopped }, "the capture opened after the stop is still open")
    }

    @Test("A start after a stop, both while the source is starting, keeps the capture it opens")
    func startAfterAStopDuringAStartKeepsTheCapture() async throws {
        let captures = StandInCaptures(held: true)
        let source = ScreenAudioSource(sourceID: "screen", openCapture: captures.open)
        let first = Task { try await source.start() }
        try await Self.waitUntil { captures.opened.count == 1 }
        try await source.stop()
        let second = Task { try await source.start() }
        try await Task.sleep(for: .milliseconds(200))   // time for a second open to begin

        captures.release()
        try await first.value
        try await second.value

        #expect(captures.opened.count == 1)
        #expect(source.isActive)
        #expect(captures.opened.allSatisfy { !$0.isStopped })
        try await source.stop()
    }

    @Test("A capture that stops by itself while the source is starting leaves the source stopped")
    func captureStoppingByItselfDuringTheStartLeavesTheSourceStopped() async throws {
        let captures = StandInCaptures(held: true)
        let source = ScreenAudioSource(sourceID: "screen", openCapture: captures.open)
        let start = Task { try await source.start() }
        try await Self.waitUntil { captures.opened.count == 1 }

        captures.opened[0].stopByItself()
        captures.release()
        try await start.value

        #expect(!source.isActive)
        try await source.start()
        #expect(captures.opened.count == 2)
        #expect(source.isActive)
    }

    /// Polls `condition` for up to five seconds.
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && .now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Stand-ins for ScreenCaptureKit captures, kept in the order they were opened. Held ones don't
/// finish opening until `release()`.
@MainActor
private final class StandInCaptures {
    private(set) var opened: [StandInCapture] = []
    private let held: OSAllocatedUnfairLock<Bool>

    init(held: Bool = false) {
        self.held = OSAllocatedUnfairLock(initialState: held)
    }

    func release() {
        held.withLock { $0 = false }
    }

    var open: OpenScreenAudioCapture {
        { [self, held] _, onStop in
            let capture = StandInCapture(onStop: onStop)
            await MainActor.run { opened.append(capture) }
            while held.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
            return capture
        }
    }
}

private final class StandInCapture: ScreenAudioCapture, @unchecked Sendable {
    private let onStop: (any Error) -> Void
    private let state = OSAllocatedUnfairLock(initialState: (stopFails: false, isStopped: false))

    init(onStop: @escaping (any Error) -> Void) {
        self.onStop = onStop
    }

    /// `stop()` throws, as it does for a stream that has already stopped.
    var stopFails: Bool {
        get { state.withLock { $0.stopFails } }
        set { state.withLock { $0.stopFails = newValue } }
    }

    /// Whether `stop()` has been called.
    var isStopped: Bool { state.withLock { $0.isStopped } }

    func stop() async throws {
        let fails = state.withLock { state in
            state.isStopped = true
            return state.stopFails
        }
        if fails { throw RecorderError.screenCaptureUnavailable }
    }

    /// The stream stops without being asked, as when the user ends sharing.
    func stopByItself() {
        onStop(RecorderError.screenCaptureUnavailable)
    }
}
#endif
