// ArkavoStreaming - Live Streaming Integration
//
// This package provides RTMP live streaming capabilities for ArkavoCreator,
// enabling multi-platform broadcasting to Twitch, YouTube, and custom RTMP servers.
//
// ## Components
//
// - `RTMPPublisher`: Core RTMP protocol implementation
// - `TwitchClient`: Twitch OAuth and stream management
// - `YouTubeClient`: YouTube Live OAuth and broadcast management
// - `StreamingSession`: High-level streaming coordinator
// - `StreamHealthMonitor`: Network quality and performance monitoring
//
// ## Usage
//
// ```swift
// // Create publisher
// let publisher = RTMPPublisher()
//
// // Connect to Twitch
// let destination = RTMPPublisher.Destination(
//     url: "rtmp://live.twitch.tv/app/\(streamKey)",
//     platform: "twitch"
// )
//
// try await publisher.connect(to: destination, streamKey: streamKey)
//
// // Publish frames (from VideoEncoder)
// try await publisher.publishVideo(buffer: videoBuffer, timestamp: timestamp)
// try await publisher.publishAudio(buffer: audioBuffer, timestamp: timestamp)
//
// // Monitor health
// let stats = await publisher.statistics
// print("Bitrate: \(stats.bitrate / 1000) kbps")
//
// // Disconnect
// await publisher.disconnect()
// ```
//
// ## Platform Integration
//
// ### Twitch
// - OAuth 2.0 with PKCE
// - Stream key management
// - Channel info and viewer stats
//
// ### YouTube
// - Google OAuth
// - Broadcast creation and management
// - Live chat integration (future)
//
// ### Custom RTMP
// - Any RTMP-compatible server
// - nginx-rtmp, Red5, Wowza, etc.
//
// ## Architecture
//
// ```
// ArkavoRecorder (Screen + Camera + Audio)
//         ↓
//   CompositorManager (Metal PiP)
//         ↓
//    VideoEncoder ──┬──> File Output (Recording)
//                   └──> RTMPPublisher (Streaming)
//                            ↓
//         ┌──────────────────┼──────────────────┐
//         ▼                  ▼                  ▼
//      Twitch            YouTube           Custom RTMP
// ```

import Foundation
