import ArkavoSocial
import Foundation
import Network
import OSLog

/// Connection status for an agent
public enum ConnectionStatus: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(reason: String)
}

/// Represents a connection to a single A2A agent
public actor AgentConnection {
    // MARK: - Properties

    public let endpoint: AgentEndpoint
    private let transport: AgentWebSocketTransport
    private var status: ConnectionStatus = .disconnected
    private var reconnectTask: Task<Void, Never>?

    // Reconnection configuration
    private let maxReconnectAttempts: Int
    private let initialBackoffMs: UInt64
    private let maxBackoffMs: UInt64

    // MARK: - Initialization

    public init(
        endpoint: AgentEndpoint,
        maxReconnectAttempts: Int = 5,
        initialBackoffMs: UInt64 = 500,
        maxBackoffMs: UInt64 = 30000
    ) {
        self.endpoint = endpoint
        self.transport = AgentWebSocketTransport(timeoutMs: 30000, requireTLS: false)
        self.maxReconnectAttempts = maxReconnectAttempts
        self.initialBackoffMs = initialBackoffMs
        self.maxBackoffMs = maxBackoffMs
    }

    // MARK: - Connection Management

    /// Connect to the agent
    public func connect() async throws {
        status = .connecting
        print("Connecting to agent \(endpoint.id) at \(endpoint.url)")

        do {
            try await transport.connect(to: endpoint)
            status = .connected
            print("Successfully connected to agent \(endpoint.id)")
        } catch {
            status = .failed(reason: error.localizedDescription)
            throw error
        }
    }

    /// Disconnect from the agent
    public func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil

        await transport.close()
        status = .disconnected
        print("Disconnected from agent \(endpoint.id)")
    }

    /// Start automatic reconnection
    public func startWithReconnection() {
        reconnectTask = Task {
            var attempt = 0
            var backoff = initialBackoffMs

            while !Task.isCancelled {
                do {
                    try await connect()

                    // Reset on successful connection
                    attempt = 0
                    backoff = initialBackoffMs

                    // Wait for disconnection
                    await waitForDisconnection()

                } catch {
                    attempt += 1

                    if attempt >= maxReconnectAttempts {
                        print("Max reconnection attempts reached for agent \(endpoint.id)")
                        break
                    }

                    await updateStatus(.reconnecting(attempt: attempt))

                    print("Reconnecting to agent \(endpoint.id) in \(backoff)ms (attempt \(attempt))")

                    // Wait before reconnecting
                    try? await Task.sleep(nanoseconds: backoff * 1_000_000)

                    // Exponential backoff with jitter
                    backoff = min(backoff * 2, maxBackoffMs)
                    let jitter = UInt64.random(in: 0...1000)
                    backoff += jitter
                }
            }
        }
    }

    /// Get the current connection status
    public func getStatus() -> ConnectionStatus {
        status
    }

    /// Check if connected
    public func isConnected() async -> Bool {
        await transport.getIsConnected()
    }

    // MARK: - Request Methods

    /// Send a JSON-RPC request to the agent
    public func sendRequest(_ request: AgentRequest) async throws -> AgentResponse {
        guard await transport.getIsConnected() else {
            throw AgentError.notConnected
        }

        return try await transport.sendRequest(request)
    }

    /// Send a request with a specific method and parameters
    public func call(method: String, params: [String: Any] = [:]) async throws -> AgentResponse {
        let request = AgentRequest(method: method, params: AnyCodable(params))
        return try await sendRequest(request)
    }

    /// Set the notification handler for this connection
    public func setNotificationHandler(_ handler: (any AgentNotificationHandler)?) async {
        await transport.setNotificationHandler(handler)
    }

    // MARK: - Private Methods

    private func waitForDisconnection() async {
        // Poll connection status
        while await transport.getIsConnected() && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
        }
    }

    private func updateStatus(_ newStatus: ConnectionStatus) {
        status = newStatus
    }
}
