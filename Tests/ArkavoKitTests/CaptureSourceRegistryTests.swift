import Testing
import Foundation
import os
@testable import ArkavoRecorder

/// A start that never finishes on its own, like a first-frame wait on a camera that never
/// delivers a frame, and ignores cancellation. Unlike a dropped continuation, which leaks its
/// task ("SWIFT TASK CONTINUATION MISUSE … leaked its continuation"), it holds the continuation
/// until `release()`, so the test leaves nothing suspended behind it.
private final class StuckStart: Sendable {
    private let state = OSAllocatedUnfairLock<(continuation: CheckedContinuation<Void, Never>?, released: Bool)>(
        initialState: (nil, false)
    )

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                if state.released { return true }
                state.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            defer { state = (nil, true) }
            return state.continuation
        }
        continuation?.resume()
    }
}

/// Recording startup waits for each capture source's first frame, but no longer than
/// the timeout, even when a source's wait ignores cancellation.
struct CaptureSourceRegistryTests {
    @Test("A source that never becomes ready times out instead of hanging startup", .timeLimit(.minutes(1)))
    func stuckSourceTimesOut() async {
        let registry = CaptureSourceRegistry()
        let stuck = StuckStart()
        // Resumed only after the timeout is checked, so the abandoned start doesn't outlive the test.
        defer { stuck.release() }
        await registry.register(RegisteredSource(sourceID: "stuck", sourceType: .camera) {
            await stuck.wait()
        })
        await registry.register(RegisteredSource(sourceID: "ready", sourceType: .screen) {})

        let result = await registry.startAllAndWaitForReady(timeout: 0.2)

        guard case .partialReady(let failed) = result else {
            Issue.record("expected the stuck source to fail, got \(result)")
            return
        }
        #expect(Array(failed.keys) == ["stuck"])
    }
}
