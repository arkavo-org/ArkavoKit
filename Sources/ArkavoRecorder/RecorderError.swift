import Foundation

public enum RecorderError: Error, Sendable {
    case screenCaptureUnavailable
    case cameraUnavailable
    case microphoneUnavailable
    case cannotAddInput
    case cannotAddOutput
    case recordingFailed
    case encodingFailed
    case permissionDenied
}

extension RecorderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .screenCaptureUnavailable:
            return "Screen capture is unavailable"
        case .cameraUnavailable:
            return "Camera is unavailable"
        case .microphoneUnavailable:
            return "Microphone is unavailable"
        case .cannotAddInput:
            return "Cannot add input to recording session"
        case .cannotAddOutput:
            return "Cannot add output to recording session"
        case .recordingFailed:
            return "Recording failed"
        case .encodingFailed:
            return "Video encoding failed. The video file may be corrupted or the recording session was not properly initialized"
        case .permissionDenied:
            return "Required permissions were denied"
        }
    }
}
