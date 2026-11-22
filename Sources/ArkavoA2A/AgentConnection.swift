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

/// Delegate for connection state changes (for session recovery)
public protocol AgentConnectionDelegate: AnyObject, Sendable {
    func connectionDidReconnect(agentId: String) async
    func connectionDidDisconnect(agentId: String, error: Error?) async
}

/// Represents a connection to a single A2A agent
public actor AgentConnection: AgentWebSocketTransportDelegate {
    // MARK: - Properties

    public let endpoint: AgentEndpoint
    private let transport: AgentWebSocketTransport
    private var status: ConnectionStatus = .disconnected
    private var reconnectTask: Task<Void, Never>?

    // Connection state delegate
    private weak var connectionDelegate: (any AgentConnectionDelegate)?

    // Reconnection configuration
    private let maxReconnectAttempts: Int
    private let initialBackoffMs: UInt64
    private let maxBackoffMs: UInt64
    private var reconnectionEnabled: Bool = false
    private var disconnectRequested: Bool = false
    private var isReconnectingAttempt: Bool = false
    private var hasEverConnected: Bool = false
    private var reconnectTaskGeneration: UInt64 = 0
    private var statusObserver: (@Sendable (ConnectionStatus) async -> Void)?

    // MARK: - Initialization

    public init(
        endpoint: AgentEndpoint,
        maxReconnectAttempts: Int = 10,
        initialBackoffMs: UInt64 = 1000,
        maxBackoffMs: UInt64 = 60000
    ) {
        self.endpoint = endpoint
        self.transport = AgentWebSocketTransport(
            timeoutMs: 30000,
            requireTLS: false,
            heartbeatIntervalMs: 30000,
            missedPongThreshold: 2
        )
        self.maxReconnectAttempts = maxReconnectAttempts
        self.initialBackoffMs = initialBackoffMs
        self.maxBackoffMs = maxBackoffMs
    }

    /// Set the connection delegate for state change notifications
    public func setConnectionDelegate(_ delegate: (any AgentConnectionDelegate)?) async {
        self.connectionDelegate = delegate
        await transport.setDelegate(self)
    }

    /// Observe status updates independently of `connectionDelegate`
    func setStatusObserver(_ observer: (@Sendable (ConnectionStatus) async -> Void)?) {
        self.statusObserver = observer
    }

    /// Enable or disable automatic reconnection on subsequent transport disconnects
    func setAutoReconnectionEnabled(_ enabled: Bool) {
        self.reconnectionEnabled = enabled
    }

    // MARK: - Connection Management

    /// Connect to the agent
    public func connect() async throws {
        disconnectRequested = false

        let wasReconnecting: Bool
        if case .reconnecting = status {
            wasReconnecting = true
        } else {
            wasReconnecting = hasEverConnected
        }
        isReconnectingAttempt = wasReconnecting

        if !wasReconnecting {
            await updateStatus(.connecting)
        }

        await transport.setDelegate(self)
        print("Connecting to agent \(endpoint.id) at \(endpoint.url)")

        do {
            try await transport.connect(to: endpoint)
            hasEverConnected = true
            isReconnectingAttempt = false
            await updateStatus(.connected)
            print("Successfully connected to agent \(endpoint.id)")
        } catch {
            isReconnectingAttempt = false
            await updateStatus(.failed(reason: error.localizedDescription))
            throw error
        }
    }

    /// Disconnect from the agent
    public func disconnect() async {
        disconnectRequested = true
        reconnectionEnabled = false
        isReconnectingAttempt = false
        hasEverConnected = false

        reconnectTaskGeneration &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil

        await transport.close()
        await updateStatus(.disconnected)
        print("Disconnected from agent \(endpoint.id)")
    }

    /// Start automatic reconnection
    public func startWithReconnection() {
        // Cancel any existing reconnect task to prevent duplicate loops
        reconnectTaskGeneration &+= 1
        let currentGeneration = reconnectTaskGeneration
        reconnectTask?.cancel()
        reconnectTask = nil

        reconnectionEnabled = true
        disconnectRequested = false

        reconnectTask = Task {
            defer {
                self.clearReconnectTaskIfCurrent(generation: currentGeneration)
            }

            await self.transport.setDelegate(self)

            var attempt = 0
            var backoff = initialBackoffMs

            while !Task.isCancelled && reconnectionEnabled && !disconnectRequested {
                do {
                    try await connect()

                    // Reset on successful connection
                    attempt = 0
                    backoff = initialBackoffMs

                    // Connection is now managed by transport delegate
                    // Wait until reconnection task is cancelled or reconnection needed
                    while !Task.isCancelled && status == .connected && !disconnectRequested {
                        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second check
                    }

                } catch {
                    if Task.isCancelled || disconnectRequested || !reconnectionEnabled {
                        break
                    }

                    attempt += 1

                    if attempt >= maxReconnectAttempts {
                        print("Max reconnection attempts reached for agent \(endpoint.id)")
                        await updateStatus(.failed(reason: "Max reconnection attempts (\(maxReconnectAttempts)) exceeded"))
                        break
                    }

                    await updateStatus(.reconnecting(attempt: attempt))

                    // Calculate backoff with jitter
                    let jitter = UInt64.random(in: 0...1000)
                    let delay = min(backoff + jitter, maxBackoffMs)

                    print("Reconnecting to agent \(endpoint.id) in \(delay)ms (attempt \(attempt)/\(maxReconnectAttempts))")

                    // Wait before reconnecting
                    try? await Task.sleep(nanoseconds: delay * 1_000_000)

                    // Exponential backoff
                    backoff = min(backoff * 2, maxBackoffMs)
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
        // Check local status first (fast, no actor hop needed)
        // This fixes a race condition where transport.isConnected might
        // not be immediately visible after connection due to actor isolation
        if status == .connected {
            return true
        }
        // Fall back to transport check for cases where status might be stale
        return await transport.getIsConnected()
    }

    // MARK: - Request Methods

    /// Send a JSON-RPC request to the agent
    public func sendRequest(_ request: AgentRequest) async throws -> AgentResponse {
        // Check local status first to avoid race condition with transport state
        let transportConnected = await transport.getIsConnected()
        guard status == .connected || transportConnected else {
            throw AgentError.notConnected
        }

        return try await transport.sendRequest(request)
    }

    /// Send a request with a specific method and dictionary parameters
    public func call(method: String, params: [String: Any] = [:]) async throws -> AgentResponse {
        let request = AgentRequest(method: method, params: AnyCodable(params))
        return try await sendRequest(request)
    }

    /// Send a request with a specific method and array parameters (for subscriptions)
    public func call(method: String, arrayParams: [Any]) async throws -> AgentResponse {
        let request = AgentRequest(method: method, params: AnyCodable(arrayParams))
        return try await sendRequest(request)
    }

    /// Set the notification handler for this connection
    public func setNotificationHandler(_ handler: (any AgentNotificationHandler)?) async {
        await transport.setNotificationHandler(handler)
    }

    // MARK: - AgentWebSocketTransportDelegate

    nonisolated public func transportDidConnect() async {
        await handleTransportConnect()
    }

    nonisolated public func transportDidDisconnect(error: Error?) async {
        await handleTransportDisconnect(error: error)
    }

    nonisolated public func transportWillReconnect(attempt: Int, delay: UInt64) async {
        await handleTransportWillReconnect(attempt: attempt, delay: delay)
    }

    private func handleTransportConnect() async {
        var wasReconnecting = isReconnectingAttempt
        if case .reconnecting = status {
            wasReconnecting = true
        }
        isReconnectingAttempt = false
        hasEverConnected = true

        await updateStatus(.connected)
        print("[AgentConnection] Transport connected (was reconnecting: \(wasReconnecting))")

        // Notify delegate if this was a reconnection
        if wasReconnecting, let delegate = connectionDelegate {
            await delegate.connectionDidReconnect(agentId: endpoint.id)
        }
    }

    private func handleTransportDisconnect(error: Error?) async {
        guard !disconnectRequested else {
            // Intentional disconnect, don't trigger reconnection
            return
        }

        print("[AgentConnection] Transport disconnected: \(error?.localizedDescription ?? "unknown")")
        await updateStatus(.disconnected)

        // Notify delegate
        if let delegate = connectionDelegate {
            await delegate.connectionDidDisconnect(agentId: endpoint.id, error: error)
        }

        // Trigger reconnection if enabled
        if reconnectionEnabled && reconnectTask == nil {
            startWithReconnection()
        }
    }

    private func handleTransportWillReconnect(attempt: Int, delay: UInt64) async {
        await updateStatus(.reconnecting(attempt: attempt))
        print("[AgentConnection] Will reconnect in \(delay)ms (attempt \(attempt))")
    }

    // MARK: - Private Methods

    private func clearReconnectTaskIfCurrent(generation: UInt64) {
        if reconnectTaskGeneration == generation {
            reconnectTask = nil
        }
    }

    private func updateStatus(_ newStatus: ConnectionStatus) async {
        status = newStatus
        if let statusObserver {
            await statusObserver(newStatus)
        }
    }
}
