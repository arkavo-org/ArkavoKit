import CoreMedia
import Foundation

/// Errors that can occur during capture source operations
public enum CaptureSourceError: Error, LocalizedError {
    case timeout(sourceID: String, after: TimeInterval)
    case notAvailable(sourceID: String, reason: String)
    case permissionDenied(sourceID: String)
    case hardwareError(sourceID: String, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case let .timeout(id, duration):
            return "Capture source '\(id)' failed to become ready after \(duration)s"
        case let .notAvailable(id, reason):
            return "Capture source '\(id)' not available: \(reason)"
        case let .permissionDenied(id):
            return "Permission denied for capture source '\(id)'"
        case let .hardwareError(id, error):
            return "Hardware error for '\(id)': \(error.localizedDescription)"
        }
    }
}

/// Types of capture sources
public enum CaptureSourceType: String, Sendable {
    case screen
    case camera
    case avatar
    case audio
}
