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
    private var discoveryGeneration: UInt64 = 0

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
        // Check existing connection state before deciding whether to reuse or replace
        var previousConnection: AgentConnection?
        if let existingConnection = connections[agent.id] {
            let existingConnected = await existingConnection.isConnected()
            let existingStatus = await existingConnection.getStatus()

            if connections[agent.id] === existingConnection {
                if existingConnected && existingConnection.endpoint.url == agent.url {
                    if isManual {
                        manualAgentIds.insert(agent.id)
                    }
                    print("Already connected to agent \(agent.id)")
                    return
                }

                // Never disrupt an active connecting/reconnecting attempt from automatic discovery
                if !isManual && existingConnection.endpoint.url == agent.url {
                    switch existingStatus {
                    case .connecting, .reconnecting:
                        return
                    default:
                        break
                    }
                }

                previousConnection = existingConnection
            } else if let latestConnection = connections[agent.id] {
                if !isManual {
                    // Another connect call superseded us while we were checking status
                    return
                }
                previousConnection = latestConnection
            }
        }

        // Install the replacement connection before disconnecting the old one so
        // `connections[agent.id]` never has a nil window across suspension points
        let connection = AgentConnection(endpoint: agent)
        connections[agent.id] = connection
        if isManual {
            manualAgentIds.insert(agent.id)
        }
        statuses[agent.id] = .connecting

        if let previousConnection {
            await previousConnection.disconnect()
            // Abort cleanly if superseded while tearing down the old connection
            guard connections[agent.id] === connection else {
                await connection.disconnect()
                return
            }
        }

        // Perform initial connection so unreachable agents are not falsely marked connected
        do {
            try await connection.connect()
            guard connections[agent.id] === connection else {
                await connection.disconnect()
                return
            }

            // Register status observer after initial handshake to avoid transient .failed flickers
            await installStatusObserver(on: connection, for: agent.id)
            statuses[agent.id] = .connected
            if autoReconnect {
                await connection.setAutoReconnectionEnabled(true)
            }
        } catch {
            if connections[agent.id] === connection {
                if autoReconnect {
                    await installStatusObserver(on: connection, for: agent.id)
                    statuses[agent.id] = .reconnecting(attempt: 1)
                    await connection.startWithReconnection(afterInitialFailure: true)
                } else {
                    connections.removeValue(forKey: agent.id)
                    if isManual {
                        manualAgentIds.remove(agent.id)
                    }
                    statuses[agent.id] = .failed(reason: error.localizedDescription)
                }
            } else {
                await connection.disconnect()
            }
            throw error
        }
    }

    private func installStatusObserver(on connection: AgentConnection, for agentId: String) async {
        await connection.setStatusObserver { [weak self, weak connection] newStatus in
            await MainActor.run {
                guard let self, let connection, self.connections[agentId] === connection else {
                    return
                }
                self.statuses[agentId] = newStatus
            }
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
                    await self.reconcileDiscoveredAgents(discoveredAgents)
                }
            }
            .store(in: &cancellables)
    }

    func reconcileDiscoveredAgents(_ discoveredAgents: [AgentEndpoint]) async {
        discoveryGeneration &+= 1
        let generation = discoveryGeneration

        // Update agents list
        self.agents = discoveredAgents

        // Auto-connect to new discovered agents
        // Note: This device's agent is NOT in mDNS discovery - it's added directly in AgentService
        // So all agents here are remote and need WebSocket connections
        if self.autoConnect {
            for agent in discoveredAgents {
                guard self.discoveryGeneration == generation else { return }
                let shouldConnect: Bool
                if self.connections[agent.id] == nil {
                    shouldConnect = true
                } else if case .failed? = self.statuses[agent.id] {
                    shouldConnect = true
                } else {
                    shouldConnect = false
                }
                if shouldConnect {
                    print("Auto-connecting to discovered agent: \(agent.id)")
                    try? await self.connect(to: agent, isManual: false)
                }
            }
        }

        // Bail out if a newer discovery update arrived while awaiting connections
        guard self.discoveryGeneration == generation else { return }

        // Remove connections for discovered agents that disappeared
        // Manually added endpoints are tracked separately and never disconnected by mDNS updates
        let discoveredIds = Set(discoveredAgents.map(\.id))
        let activeIds = Array(self.connections.keys)
        for agentId in activeIds {
            guard self.discoveryGeneration == generation else { return }
            if !discoveredIds.contains(agentId) && !self.manualAgentIds.contains(agentId) {
                print("Agent \(agentId) disappeared, disconnecting")
                await self.disconnect(from: agentId)
            }
        }
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
