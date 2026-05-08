import XCTest
@testable import ArkavoSocial

/// Pure-function unit tests for the YouTube resumable-upload Range header parser.
/// The parser drives the 308 "Resume Incomplete" branch — when the server reports
/// it accepted bytes 0-N, we resume from N+1.
final class YouTubeUploadRangeTests: XCTestCase {
    func testParsesNormalRange() {
        let next = YouTubeClient.nextOffsetFromRangeHeader("bytes=0-8388607")
        XCTAssertEqual(next, 8_388_608)
    }

    func testParsesPartialAcceptance() {
        // Server acknowledged less than we sent — common on flaky networks.
        let next = YouTubeClient.nextOffsetFromRangeHeader("bytes=0-1048575")
        XCTAssertEqual(next, 1_048_576)
    }

    func testHandlesMultiSegmentSentBytes() {
        // After resume, the server may report the highest contiguous byte received
        // including bytes from a prior chunk.
        let next = YouTubeClient.nextOffsetFromRangeHeader("bytes=0-16777215")
        XCTAssertEqual(next, 16_777_216)
    }

    func testReturnsNilForMissingHeader() {
        XCTAssertNil(YouTubeClient.nextOffsetFromRangeHeader(nil))
    }

    func testReturnsNilForMalformedHeader() {
        XCTAssertNil(YouTubeClient.nextOffsetFromRangeHeader("garbage"))
        XCTAssertNil(YouTubeClient.nextOffsetFromRangeHeader("bytes=0-notanumber"))
    }

    func testZeroBytesAccepted() {
        // Edge: server received the request but committed nothing yet.
        // Header would be `bytes=0-0` meaning byte 0 is accepted, resume at 1.
        // But the resumable protocol actually OMITS the Range header in this case.
        // Defensive: if it does appear, we trust it.
        let next = YouTubeClient.nextOffsetFromRangeHeader("bytes=0-0")
        XCTAssertEqual(next, 1)
    }
}
