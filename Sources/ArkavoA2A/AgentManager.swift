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
    private var manualAgentIds: Set<String> = []

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
        try await connect(to: agent, isManual: true)
    }

    private func connect(to agent: AgentEndpoint, isManual: Bool) async throws {
        // Check if already connected
        if let existingConnection = connections[agent.id] {
            if await existingConnection.isConnected() {
                if isManual {
                    manualAgentIds.insert(agent.id)
                }
                print("Already connected to agent \(agent.id)")
                return
            }
            // Disconnect stale connection before replacing
            connections.removeValue(forKey: agent.id)
            await existingConnection.disconnect()
        }

        // Create new connection
        let connection = AgentConnection(endpoint: agent)
        connections[agent.id] = connection
        if isManual {
            manualAgentIds.insert(agent.id)
        }

        // Observe real status transitions from the connection
        await connection.setStatusObserver { [weak self, weak connection] newStatus in
            await MainActor.run {
                guard let self, let connection, self.connections[agent.id] === connection else {
                    return
                }
                self.statuses[agent.id] = newStatus
            }
        }

        // Update status
        statuses[agent.id] = .connecting

        // Perform initial connection so unreachable agents are not falsely marked connected
        do {
            try await connection.connect()
            if connections[agent.id] === connection {
                statuses[agent.id] = .connected
                if autoReconnect {
                    await connection.setAutoReconnectionEnabled(true)
                }
            }
        } catch {
            if connections[agent.id] === connection {
                statuses[agent.id] = .failed(reason: error.localizedDescription)
            }
            throw error
        }
    }

    /// Disconnect from a specific agent
    public func disconnect(from agentId: String) async {
        manualAgentIds.remove(agentId)
        guard let connection = connections.removeValue(forKey: agentId) else {
            return
        }

        await connection.disconnect()
        if connections[agentId] == nil {
            statuses[agentId] = .disconnected
        }
    }

    /// Disconnect from all agents
    public func disconnectAll() async {
        let snapshot = connections
        for (agentId, connection) in snapshot {
            if connections[agentId] === connection {
                connections.removeValue(forKey: agentId)
                manualAgentIds.remove(agentId)
            }
            await connection.disconnect()
            if connections[agentId] == nil {
                statuses[agentId] = .disconnected
            }
        }
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

                    // Auto-connect to new discovered agents
                    // Note: This device's agent is NOT in mDNS discovery - it's added directly in AgentService
                    // So all agents here are remote and need WebSocket connections
                    if self.autoConnect {
                        for agent in discoveredAgents {
                            if self.connections[agent.id] == nil {
                                print("Auto-connecting to discovered agent: \(agent.id)")
                                try? await self.connect(to: agent, isManual: false)
                            }
                        }
                    }

                    // Remove connections for discovered agents that disappeared
                    // Manually added endpoints are tracked separately and never disconnected by mDNS updates
                    let discoveredIds = Set(discoveredAgents.map(\.id))
                    let activeIds = Array(self.connections.keys)
                    for agentId in activeIds {
                        if !discoveredIds.contains(agentId) && !self.manualAgentIds.contains(agentId) {
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
