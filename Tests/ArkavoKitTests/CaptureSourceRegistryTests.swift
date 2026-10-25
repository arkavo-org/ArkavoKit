import Testing
import Foundation
@testable import ArkavoRecorder

/// Recording startup waits for each capture source's first frame, but no longer than
/// the timeout, even when a source's wait ignores cancellation.
struct CaptureSourceRegistryTests {
    @Test("A source that never becomes ready times out instead of hanging startup", .timeLimit(.minutes(1)))
    func stuckSourceTimesOut() async {
        let registry = CaptureSourceRegistry()
        await registry.register(RegisteredSource(sourceID: "stuck", sourceType: .camera) {
            // Like a first-frame wait on a camera that never delivers a frame:
            // a continuation that nothing resumes, not even cancellation
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
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
