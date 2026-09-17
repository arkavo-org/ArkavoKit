import XCTest
import Network
import os
@testable import ArkavoStreaming

/// `RTMPPublisher.connect` must fail within a bounded time when the RTMP host
/// refuses or never answers. `NWConnection` reports ECONNREFUSED as
/// `.waiting(error)` and keeps retrying, so without a connect timeout the
/// awaiting continuation is never resumed and the caller hangs forever.
final class RTMPPublisherConnectTimeoutTests: XCTestCase {

    func testConnectToClosedPortThrowsWithinConnectTimeout() async throws {
        let connectTimeout: TimeInterval = 2
        let testDeadline: TimeInterval = 5

        let publisher = RTMPPublisher(connectTimeout: connectTimeout)
        let destination = RTMPPublisher.Destination(url: "rtmp://127.0.0.1:1/live", platform: "custom")

        let finished = expectation(description: "connect(to:) returns")
        let result = OSAllocatedUnfairLock<Result<Void, Error>?>(initialState: nil)
        let started = Date()
        // Unstructured on purpose: if connect hangs, the task leaks instead of
        // blocking this test function forever (a task group would wait on it).
        Task {
            do {
                try await publisher.connect(to: destination, streamKey: "key")
                result.withLock { $0 = .success(()) }
            } catch {
                result.withLock { $0 = .failure(error) }
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: testDeadline)
        let elapsed = Date().timeIntervalSince(started)

        switch result.withLock({ $0 }) {
        case nil:
            XCTFail("connect(to:) did not return within \(testDeadline)s (connectTimeout was \(connectTimeout)s): it is hung")
        case .success:
            XCTFail("connect(to:) succeeded against a closed port")
        case .failure(let error):
            XCTAssertLessThan(elapsed, testDeadline, "connect(to:) took \(elapsed)s")
            XCTAssertGreaterThanOrEqual(elapsed, connectTimeout - 0.5,
                                        "connect(to:) gave up before the connect timeout elapsed (\(elapsed)s)")

            guard case RTMPPublisher.RTMPError.connectionTimedOut(let seconds, let lastError) = error else {
                XCTFail("Expected RTMPError.connectionTimedOut, got \(error)")
                return
            }
            XCTAssertEqual(seconds, connectTimeout)
            XCTAssertNotNil(lastError, "The last NWError reported by .waiting should be carried on the thrown error")

            let description = error.localizedDescription.lowercased()
            XCTAssertTrue(description.contains("timed out"), "Description should say the connect timed out; got: \(error.localizedDescription)")
            XCTAssertTrue(description.contains("refused"), "Description should surface the underlying ECONNREFUSED; got: \(error.localizedDescription)")
        }

        // The publisher must be left in a state that reports the failure.
        let state = await publisher.currentState
        guard case .error = state else {
            return XCTFail("Expected publisher state .error after a timed-out connect, got \(state)")
        }
    }
}
