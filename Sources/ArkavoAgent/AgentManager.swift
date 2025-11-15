import Foundation
import Combine

/// Manages connections to multiple A2A agents with automatic discovery
@MainActor
public final class AgentManager: ObservableObject {
    // MARK: - Singleton

    public static let shared = AgentManager()

    // MARK: - Published Properties

    /// All discovered agents
    @Published public private(set) var agents: [AgentEndpoint] = []

    /// Active connections by agent ID
    @Published public private(set) var connections: [String: AgentConnection] = [:]

    /// Connection statuses by agent ID
    @Published public private(set) var statuses: [String: ConnectionStatus] = [:]

    // MARK: - Private Properties

    private let discoveryService: AgentDiscoveryService
    private var cancellables = Set<AnyCancellable>()

    // Configuration
    private let autoConnect: Bool
    private let autoReconnect: Bool

    // MARK: - Initialization

    public init(autoConnect: Bool = true, autoReconnect: Bool = true) {
        self.autoConnect = autoConnect
        self.autoReconnect = autoReconnect
        self.discoveryService = AgentDiscoveryService()

        setupDiscoveryObserver()
    }

    // MARK: - Discovery

    /// Start discovering agents on the local network
    public func startDiscovery() {
        discoveryService.startDiscovery()
    }

    /// Stop discovering agents
    public func stopDiscovery() {
        discoveryService.stopDiscovery()
    }

    /// Get discovery state
    public var isDiscovering: Bool {
        discoveryService.isDiscovering
    }

    // MARK: - Connection Management

    /// Connect to a specific agent
    public func connect(to agent: AgentEndpoint) async throws {
        // Check if already connected
        if let connection = connections[agent.id] {
            if await connection.isConnected() {
                print("Already connected to agent \(agent.id)")
                return
            }
        }

        // Create new connection
        let connection = AgentConnection(endpoint: agent)
        connections[agent.id] = connection

        // Update status
        statuses[agent.id] = .connecting

        // Connect
        do {
            if autoReconnect {
                await connection.startWithReconnection()
            } else {
                try await connection.connect()
            }

            statuses[agent.id] = .connected
        } catch {
            statuses[agent.id] = .failed(reason: error.localizedDescription)
            throw error
        }
    }

    /// Disconnect from a specific agent
    public func disconnect(from agentId: String) async {
        guard let connection = connections.removeValue(forKey: agentId) else {
            return
        }

        await connection.disconnect()
        statuses[agentId] = .disconnected
    }

    /// Disconnect from all agents
    public func disconnectAll() async {
        for (agentId, connection) in connections {
            await connection.disconnect()
            statuses[agentId] = .disconnected
        }
        connections.removeAll()
    }

    /// Get connection to an agent
    public func getConnection(for agentId: String) -> AgentConnection? {
        connections[agentId]
    }

    // MARK: - Request Methods

    /// Send a request to a specific agent
    public func sendRequest(
        to agentId: String,
        method: String,
        params: [String: Any] = [:]
    ) async throws -> AgentResponse {
        guard let connection = connections[agentId] else {
            throw AgentError.notConnected
        }

        nonisolated(unsafe) let unsafeParams = params
        return try await connection.call(method: method, params: unsafeParams)
    }

    // MARK: - Private Methods

    private func setupDiscoveryObserver() {
        discoveryService.$discoveredAgents
            .sink { [weak self] discoveredAgents in
                guard let self = self else { return }

                Task { @MainActor in
                    // Update agents list
                    self.agents = discoveredAgents

                    // Auto-connect to new agents (skip LocalAIAgent - it's in-process)
                    if self.autoConnect {
                        for agent in discoveredAgents {
                            // Skip LocalAIAgent - it doesn't need WebSocket connection
                            let isLocalAgent = agent.id.lowercased().contains("local")
                            if !isLocalAgent && self.connections[agent.id] == nil {
                                print("Auto-connecting to discovered agent: \(agent.id)")
                                try? await self.connect(to: agent)
                            }
                        }
                    }

                    // Remove connections for agents that disappeared
                    let discoveredIds = Set(discoveredAgents.map(\.id))
                    for agentId in self.connections.keys {
                        if !discoveredIds.contains(agentId) {
                            print("Agent \(agentId) disappeared, disconnecting")
                            await self.disconnect(from: agentId)
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Telemetry

    /// Get connection statistics
    public func getConnectionStats() async -> [String: Any] {
        var connectedCount = 0
        for connection in connections.values {
            if await connection.isConnected() {
                connectedCount += 1
            }
        }

        return [
            "total_agents": agents.count,
            "connected": connectedCount,
            "discovering": isDiscovering
        ]
    }
}
