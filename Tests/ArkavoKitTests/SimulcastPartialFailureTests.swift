import XCTest
@testable import ArkavoRecorder
@testable import ArkavoStreaming

/// Integration test for the round-2 simulcast partial-success contract.
/// Hits localhost on closed ports so all destinations fail fast — verifies that
/// VideoEncoder.startStreaming(to:) throws `StreamingError.allDestinationsFailed`
/// and populates `streamConnectionErrors` per destination.
///
/// We deliberately don't test the "one fails, others succeed" branch here:
/// that requires standing up an RTMP server. The all-fail branch alone is
/// enough to lock in the contract that single-destination failures don't
/// kill the entire group prematurely (otherwise one would error out before
/// the others are even attempted).
final class SimulcastPartialFailureTests: XCTestCase {
    func testAllDestinationsFailedThrowsStreamingError() async throws {
        let encoder = ArkavoRecorder.VideoEncoder()
        let destinations: [(id: String, destination: ArkavoStreaming.RTMPPublisher.Destination, streamKey: String)] = [
            (id: "twitch",
             destination: ArkavoStreaming.RTMPPublisher.Destination(url: "rtmp://127.0.0.1:1/app", platform: "twitch"),
             streamKey: "test_key_twitch_value"),
            (id: "youtube",
             destination: ArkavoStreaming.RTMPPublisher.Destination(url: "rtmp://127.0.0.1:1/live2", platform: "youtube"),
             streamKey: "test_key_youtube_value"),
        ]

        do {
            try await encoder.startStreaming(to: destinations)
            XCTFail("Expected StreamingError.allDestinationsFailed; startStreaming returned successfully")
        } catch let ArkavoRecorder.VideoEncoder.StreamingError.allDestinationsFailed(summary) {
            XCTAssertTrue(summary.contains("twitch") || summary.contains("youtube"),
                          "Summary should mention destination ids; got: \(summary)")
        } catch {
            XCTFail("Expected StreamingError.allDestinationsFailed, got: \(error)")
        }

        // Per-destination errors should be exposed for UI consumption.
        let errors = await encoder.streamConnectionErrors
        XCTAssertEqual(errors.count, 2, "Both destinations should have recorded an error")
        XCTAssertNotNil(errors["twitch"])
        XCTAssertNotNil(errors["youtube"])
    }
}
