import Foundation

/// ArkavoAgent - Swift library for A2A (Agent-to-Agent) protocol communication
///
/// This library provides:
/// - mDNS service discovery for local network agents
/// - WebSocket transport with JSON-RPC 2.0
/// - Connection management with automatic reconnection
/// - Chat session protocol support
/// - Integration with Apple Intelligence
///
/// ## Usage
///
/// ```swift
/// import ArkavoKit
///
/// // Start discovering agents
/// let manager = AgentManager.shared
/// manager.startDiscovery()
///
/// // Connect to an agent
/// if let agent = manager.agents.first {
///     try await manager.connect(to: agent)
/// }
///
/// // Open a chat session
/// let chatManager = AgentChatSessionManager(agentManager: manager)
/// let session = try await chatManager.openSession(with: agentId)
///
/// // Send a message
/// try await chatManager.sendMessage(sessionId: session.id, content: "Hello!")
/// ```

// Re-export all public types for convenience
@_exported import Foundation
@_exported import Combine

// MARK: - Version

/// ArkavoAgent library version
public let ArkavoAgentVersion = "1.0.0"

/// ArkavoAgent library build
public let ArkavoAgentBuild = "1"

// MARK: - Public API Surface

// Core types are automatically exported via their public declarations
// This file serves as the main entry point for documentation and version info
