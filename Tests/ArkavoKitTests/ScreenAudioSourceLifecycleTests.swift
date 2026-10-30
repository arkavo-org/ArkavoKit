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

    @Test("A stop while the source is starting returns only once the capture it opens is stopped")
    func stopDuringAStartReturnsOnceTheCaptureIsStopped() async throws {
        let captures = StandInCaptures(held: true)
        let source = ScreenAudioSource(sourceID: "screen", openCapture: captures.open)
        let start = Task { try await source.start() }
        try await Self.waitUntil { captures.opened.count == 1 }

        let stop = StopCall(source, capture: captures.opened[0])
        try await Task.sleep(for: .milliseconds(200))   // time for a stop that doesn't wait to return
        #expect(!stop.hasReturned, "the stop returned while the capture was still opening")
        captures.release()
        try await start.value
        try await stop.waitForReturn()

        #expect(stop.captureWasStoppedOnReturn == true, "the stop returned before the capture was stopped")
        #expect(!source.isActive)
        #expect(captures.opened.allSatisfy { $0.isStopped }, "the capture opened after the stop is still open")
    }

    @Test("A start after a stop, both while the source is starting, keeps the capture it opens, and the stop returns")
    func startAfterAStopDuringAStartKeepsTheCapture() async throws {
        let captures = StandInCaptures(held: true)
        let source = ScreenAudioSource(sourceID: "screen", openCapture: captures.open)
        let first = Task { try await source.start() }
        try await Self.waitUntil { captures.opened.count == 1 }
        let stop = StopCall(source)
        try await Task.sleep(for: .milliseconds(200))   // time for the stop to begin
        let second = Task { try await source.start() }
        try await Task.sleep(for: .milliseconds(200))   // time for a second open to begin

        captures.release()
        try await first.value
        try await second.value
        try await stop.waitForReturn()

        #expect(stop.hasReturned, "the stop the second start cancelled never returned")
        #expect(captures.opened.count == 1)
        #expect(source.isActive)
        #expect(captures.opened.allSatisfy { !$0.isStopped })
        try await source.stop()
    }

    @Test("A stop while the source is starting returns when the capture fails to open")
    func stopDuringAStartWhoseOpenFailsReturns() async throws {
        let captures = StandInCaptures(held: true, failing: true)
        let source = ScreenAudioSource(sourceID: "screen", openCapture: captures.open)
        let start = Task { try await source.start() }
        try await Self.waitUntil { captures.opened.count == 1 }
        let stop = StopCall(source)
        try await Task.sleep(for: .milliseconds(200))   // time for the stop to begin

        captures.release()
        await #expect(throws: RecorderError.screenCaptureUnavailable) { try await start.value }
        try await stop.waitForReturn()

        #expect(stop.hasReturned, "the stop never returned")
        #expect(!source.isActive)
    }

    @Test("A stop while the capture is still opening returns within its time limit, and the start stops the capture once it opens")
    func stopWaitingOnAnOpeningReturnsWithinItsLimit() async throws {
        let captures = StandInCaptures(held: true)
        let source = ScreenAudioSource(sourceID: "screen", openCapture: captures.open, stopWaitLimit: .milliseconds(100))
        let start = Task { try await source.start() }
        try await Self.waitUntil { captures.opened.count == 1 }

        let stop = StopCall(source, capture: captures.opened[0])
        try await stop.waitForReturn()

        #expect(stop.hasReturned, "the stop is still waiting on an open that hasn't finished")
        #expect(stop.captureWasStoppedOnReturn == false)
        captures.release()
        try await start.value
        #expect(captures.opened.allSatisfy { $0.isStopped }, "the start kept the capture a stop asked for")
        #expect(!source.isActive)
    }

    @Test("An open that finishes as the stop's time limit runs out resumes the stop once")
    func openFinishingAtTheStopsLimitResumesItOnce() async throws {
        // Each round releases the open within a few milliseconds of the 50 ms limit, either side.
        for releaseAfter in [40, 45, 50, 55, 60] {
            let captures = StandInCaptures(held: true)
            let source = ScreenAudioSource(sourceID: "screen", openCapture: captures.open, stopWaitLimit: .milliseconds(50))
            let start = Task { try await source.start() }
            try await Self.waitUntil { captures.opened.count == 1 }

            let stop = StopCall(source)
            try await Task.sleep(for: .milliseconds(releaseAfter))
            captures.release()
            try await start.value
            try await stop.waitForReturn()

            #expect(stop.hasReturned, "release after \(releaseAfter) ms: the stop never returned")
            #expect(captures.opened.allSatisfy { $0.isStopped }, "release after \(releaseAfter) ms: the capture is still open")
            #expect(!source.isActive)
        }
    }

    @Test("A capture that stops by itself while the source is starting fails the start and leaves the source stopped")
    func captureStoppingByItselfDuringTheStartFailsIt() async throws {
        let captures = StandInCaptures(held: true)
        let source = ScreenAudioSource(sourceID: "screen", openCapture: captures.open)
        let start = Task { try await source.start() }
        try await Self.waitUntil { captures.opened.count == 1 }

        captures.opened[0].stopByItself()
        captures.release()
        await #expect(throws: RecorderError.screenCaptureUnavailable) { try await start.value }

        #expect(!source.isActive)
        try await source.start()
        #expect(captures.opened.count == 2)
        #expect(source.isActive)
    }

    @Test("A start that joined an opening whose capture stops by itself fails with it")
    func joinedStartFailsWhenTheCaptureStopsByItself() async throws {
        let captures = StandInCaptures(held: true)
        let source = ScreenAudioSource(sourceID: "screen", openCapture: captures.open)
        let first = Task { try await source.start() }
        try await Self.waitUntil { captures.opened.count == 1 }
        let second = Task { try await source.start() }
        try await Task.sleep(for: .milliseconds(200))   // time for the second start to join

        captures.opened[0].stopByItself()
        captures.release()
        await #expect(throws: RecorderError.screenCaptureUnavailable) { try await first.value }
        await #expect(throws: RecorderError.screenCaptureUnavailable) { try await second.value }

        #expect(captures.opened.count == 1)
        #expect(!source.isActive)
    }

    @Test("A stop during the start wins over the capture stopping by itself: the start returns")
    func stopDuringTheStartWinsOverTheCaptureStoppingByItself() async throws {
        let captures = StandInCaptures(held: true)
        let source = ScreenAudioSource(sourceID: "screen", openCapture: captures.open)
        let start = Task { try await source.start() }
        try await Self.waitUntil { captures.opened.count == 1 }

        let stop = StopCall(source, capture: captures.opened[0])
        try await Task.sleep(for: .milliseconds(200))   // time for the stop to begin
        captures.opened[0].stopByItself()
        captures.release()
        try await start.value
        try await stop.waitForReturn()

        #expect(stop.captureWasStoppedOnReturn == true)
        #expect(!source.isActive)
        #expect(captures.opened.allSatisfy { $0.isStopped })
    }

    /// Polls `condition` for up to five seconds.
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() && .now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Stand-ins for ScreenCaptureKit captures, kept in the order their opens began. Held ones don't
/// finish opening until `release()`; failing ones then throw instead of opening.
@MainActor
private final class StandInCaptures {
    private(set) var opened: [StandInCapture] = []
    private let held: OSAllocatedUnfairLock<Bool>
    private let failing: Bool

    init(held: Bool = false, failing: Bool = false) {
        self.held = OSAllocatedUnfairLock(initialState: held)
        self.failing = failing
    }

    func release() {
        held.withLock { $0 = false }
    }

    var open: OpenScreenAudioCapture {
        { [self, held, failing] _, onStop in
            let capture = StandInCapture(onStop: onStop)
            await MainActor.run { opened.append(capture) }
            while held.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
            if failing { throw RecorderError.screenCaptureUnavailable }
            return capture
        }
    }
}

/// A `stop()` made in a task, so a test can make it while the source is starting and wait for it
/// with a timeout: a stop that never returns fails the test instead of hanging it.
@MainActor
private final class StopCall {
    /// Nil until the stop returns; then whether `capture` had been stopped by then.
    private let returned = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    init(_ source: ScreenAudioSource, capture: StandInCapture? = nil) {
        let returned = returned
        Task {
            try? await source.stop()
            returned.withLock { $0 = capture?.isStopped ?? true }
        }
    }

    var hasReturned: Bool { returned.withLock { $0 != nil } }

    /// Whether the capture had been stopped when the stop returned; nil before it returns.
    var captureWasStoppedOnReturn: Bool? { returned.withLock { $0 } }

    /// Polls for up to five seconds for the stop to return.
    func waitForReturn() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !hasReturned && .now < deadline {
            try await Task.sleep(for: .milliseconds(10))
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
