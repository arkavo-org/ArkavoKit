import AVFoundation
import XCTest

@testable import ArkavoRecorder

/// Locks in the contract that a camera which fails to start is surfaced to the caller
/// instead of being swallowed by a `print` inside `RecordingSession`.
///
/// `testMessageMapping*` are pure unit tests. `testStartCameraPreview*` are
/// integration-style: they construct a real `RecordingSession` (AVCaptureSession +
/// Metal device + VideoEncoder) but use a camera identifier that cannot exist, so
/// `AVCaptureDevice(uniqueID:)` returns nil before any `AVCaptureDeviceInput` is
/// created and TCC/camera hardware is never touched.
@MainActor
final class CameraStartFailureTests: XCTestCase {
    private final class FailureBox: @unchecked Sendable {
        var failures: [CameraStartFailure] = []
    }

    // MARK: - Pure message mapping

    func testMessageMappingDistinguishesRecorderErrorCases() {
        let unavailable = CameraStartFailure.message(for: RecorderError.cameraUnavailable)
        let cannotAdd = CameraStartFailure.message(for: RecorderError.cannotAddInput)
        let denied = CameraStartFailure.message(for: RecorderError.permissionDenied)

        for message in [unavailable, cannotAdd, denied] {
            XCTAssertFalse(message.isEmpty)
        }
        XCTAssertNotEqual(unavailable, cannotAdd)
        XCTAssertNotEqual(unavailable, denied)
        XCTAssertNotEqual(cannotAdd, denied)
    }

    func testMessageMappingRecognisesAVFoundationCodes() {
        func avError(_ code: AVError.Code) -> Error {
            NSError(domain: AVFoundationErrorDomain, code: code.rawValue)
        }

        let notAuthorized = CameraStartFailure.message(for: avError(.applicationIsNotAuthorizedToUseDevice))
        let notConnected = CameraStartFailure.message(for: avError(.deviceNotConnected))
        let inUse = CameraStartFailure.message(for: avError(.deviceInUseByAnotherApplication))
        let inUseBySession = CameraStartFailure.message(for: avError(.deviceAlreadyUsedByAnotherSession))

        XCTAssertEqual(notAuthorized, CameraStartFailure.message(for: RecorderError.permissionDenied))
        XCTAssertEqual(notConnected, CameraStartFailure.message(for: RecorderError.cameraUnavailable))
        XCTAssertEqual(inUse, CameraStartFailure.message(for: RecorderError.cannotAddInput))
        XCTAssertEqual(inUseBySession, inUse)
        XCTAssertNotEqual(notAuthorized, notConnected)
        XCTAssertNotEqual(notConnected, inUse)
    }

    func testMessageMappingFallsBackToLocalizedDescription() {
        struct Other: LocalizedError {
            var errorDescription: String? { "Something exotic" }
        }
        let message = CameraStartFailure.message(for: Other())
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(message.contains("Something exotic"))
    }

    // MARK: - Integration (real RecordingSession, nonexistent camera id)

    func testStartCameraPreviewReportsFailureAndThrowsWhenOnlySourceFails() throws {
        let session = try RecordingSession()
        let box = FailureBox()
        session.cameraStartFailureHandler = { failure in
            box.failures.append(failure)
        }

        XCTAssertThrowsError(try session.startCameraPreview(for: ["nonexistent-camera-id"])) { error in
            guard case RecorderError.allCameraSourcesFailed = error else {
                return XCTFail("Expected allCameraSourcesFailed, got \(error)")
            }
        }

        XCTAssertEqual(box.failures.count, 1)
        XCTAssertEqual(box.failures.first?.sourceID, "nonexistent-camera-id")
        XCTAssertFalse(box.failures.first?.message.isEmpty ?? true)
        XCTAssertNil(session.getCameraPreview(), "A failed camera must not leave a dead preview session behind")
    }

    func testStartCameraPreviewRetriesAfterFailure() throws {
        let session = try RecordingSession()
        let box = FailureBox()
        session.cameraStartFailureHandler = { failure in
            box.failures.append(failure)
        }

        XCTAssertThrowsError(try session.startCameraPreview(for: ["nonexistent-camera-id"]))
        XCTAssertThrowsError(try session.startCameraPreview(for: ["nonexistent-camera-id"]))

        XCTAssertEqual(box.failures.count, 2, "A failed camera must be retried on the next start, not skipped as already running")
    }

    func testAllCameraSourcesFailedHasDescription() {
        let description = RecorderError.allCameraSourcesFailed.errorDescription ?? ""
        XCTAssertFalse(description.isEmpty)
    }
}
