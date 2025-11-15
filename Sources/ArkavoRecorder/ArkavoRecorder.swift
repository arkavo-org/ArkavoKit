// ArkavoRecorder - Simplified screen + camera + audio recording with PiP composition
//
// This package provides the core recording infrastructure for ArkavoCreator's
// OBS-style broadcast studio functionality.
//
// ## Key Components
//
// - `RecordingSession`: High-level coordinator for screen, camera, and audio capture
// - `ScreenCaptureManager`: Screen capture using AVFoundation
// - `CameraManager`: Camera capture with device selection
// - `AudioManager`: Microphone input with level monitoring
// - `CompositorManager`: Metal-based PiP composition
// - `VideoEncoder`: H.264 encoding to MOV files
//
// ## Usage
//
// ```swift
// let session = try RecordingSession()
// session.pipPosition = .bottomRight
// try await session.startRecording(outputURL: url, title: "My Recording")
// // ... record ...
// let outputURL = try await session.stopRecording()
// ```

import Foundation
