import Foundation
import Combine

/// Service for discovering A2A agents on the local network using mDNS/Bonjour
@MainActor
public final class AgentDiscoveryService: NSObject, ObservableObject {
    // MARK: - Published Properties

    /// Discovered agents
    @Published public private(set) var discoveredAgents: [AgentEndpoint] = []

    /// Discovery state
    @Published public private(set) var isDiscovering: Bool = false

    /// Last error
    @Published public private(set) var lastError: String?

    // MARK: - Private Properties

    private let serviceBrowser: NetServiceBrowser
    private var resolvingServices: Set<NetService> = []
    private var agentsByServiceName: [String: AgentEndpoint] = [:]

    // Service type for A2A agents
    private static let serviceType = "_a2a._tcp."
    private static let serviceDomain = "local."

    // MARK: - Initialization

    public override init() {
        self.serviceBrowser = NetServiceBrowser()
        super.init()
        serviceBrowser.delegate = self
    }

    // MARK: - Public Methods

    /// Start discovering agents
    public func startDiscovery() {
        guard !isDiscovering else { return }

        print("Starting mDNS discovery for \(Self.serviceType)")
        isDiscovering = true
        lastError = nil

        serviceBrowser.searchForServices(
            ofType: Self.serviceType,
            inDomain: Self.serviceDomain
        )
    }

    /// Stop discovering agents
    public func stopDiscovery() {
        guard isDiscovering else { return }

        print("Stopping mDNS discovery")
        serviceBrowser.stop()
        isDiscovering = false

        // Stop resolving any services
        for service in resolvingServices {
            service.stop()
        }
        resolvingServices.removeAll()
    }

    /// Clear discovered agents
    public func clearAgents() {
        discoveredAgents.removeAll()
        agentsByServiceName.removeAll()
    }

    // MARK: - Private Methods

    private func handleServiceDiscovered(_ service: NetService) {
        print("Discovered service: \(service.name)")

        // Start resolving the service to get host/port
        resolvingServices.insert(service)
        service.delegate = self
        service.resolve(withTimeout: 10.0)
    }

    private func handleServiceRemoved(_ service: NetService) {
        print("Service removed: \(service.name)")

        // Remove from discovered agents
        if let agent = agentsByServiceName.removeValue(forKey: service.name) {
            discoveredAgents.removeAll { $0.id == agent.id }
        }
    }

    private func handleServiceResolved(_ service: NetService) {
        resolvingServices.remove(service)

        guard let addresses = service.addresses, !addresses.isEmpty else {
            print("Service \(service.name) has no addresses")
            return
        }

        // Get the first IPv4 address
        guard let host = getHostFromAddress(addresses.first!) else {
            print("Failed to parse address for service \(service.name)")
            return
        }

        let port = service.port

        // Parse TXT record for agent metadata
        let metadata = parseTXTRecord(service.txtRecordData())

        // Extract agent ID from service name or TXT record
        var agentId = service.name
        if agentId.hasPrefix("arkavo-agent-") {
            agentId = String(agentId.dropFirst("arkavo-agent-".count))
        }
        if let txtAgentId = metadata["agent_id"] {
            agentId = txtAgentId
        }

        // Create agent endpoint
        // Note: LocalAIAgent uses NW WebSocket (no path routing), arkavo-edge uses /ws path
        // Check if this is a LocalAIAgent by looking for "local" in agent_id or purpose
        let isLocalAgent = agentId.lowercased().contains("local") ||
                          (metadata["purpose"] ?? "").lowercased().contains("local")
        let wsPath = isLocalAgent ? "" : "/ws"

        let endpoint = AgentEndpoint(
            id: agentId,
            url: "ws://\(host):\(port)\(wsPath)",
            publicKey: nil,
            metadata: AgentMetadata(
                name: metadata["name"] ?? agentId,
                purpose: metadata["purpose"] ?? "Agent discovered via mDNS",
                model: metadata["model"] ?? "Unknown",
                properties: metadata
            )
        )

        print("Resolved agent: \(endpoint.id) at \(endpoint.url)")

        // Add or update agent
        agentsByServiceName[service.name] = endpoint
        if !discoveredAgents.contains(where: { $0.id == endpoint.id }) {
            discoveredAgents.append(endpoint)
        } else {
            // Update existing agent
            if let index = discoveredAgents.firstIndex(where: { $0.id == endpoint.id }) {
                discoveredAgents[index] = endpoint
            }
        }
    }

    private func parseTXTRecord(_ data: Data?) -> [String: String] {
        guard let data = data else { return [:] }

        let txtRecord = NetService.dictionary(fromTXTRecord: data)
        var result: [String: String] = [:]

        for (key, value) in txtRecord {
            if let stringValue = String(data: value, encoding: .utf8) {
                result[key] = stringValue
            }
        }

        return result
    }

    private func getHostFromAddress(_ addressData: Data) -> String? {
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))

        addressData.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) -> Void in
            guard let baseAddress = pointer.baseAddress else { return }
            let sockaddrPtr = baseAddress.assumingMemoryBound(to: sockaddr.self)

            getnameinfo(
                sockaddrPtr,
                socklen_t(addressData.count),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
        }

        return String(cString: hostname)
    }
}

// MARK: - NetServiceBrowserDelegate

extension AgentDiscoveryService: @preconcurrency NetServiceBrowserDelegate {
    public func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        print("NetServiceBrowser will start searching")
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        handleServiceDiscovered(service)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        handleServiceRemoved(service)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        let errorCode = errorDict[NetService.errorCode] ?? -1
        let errorMessage = "Discovery failed with error code: \(errorCode)"
        print(errorMessage)
        lastError = errorMessage
        isDiscovering = false
    }

    public func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        print("NetServiceBrowser stopped searching")
        isDiscovering = false
    }
}

// MARK: - NetServiceDelegate

extension AgentDiscoveryService: @preconcurrency NetServiceDelegate {
    public func netServiceDidResolveAddress(_ sender: NetService) {
        handleServiceResolved(sender)
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolvingServices.remove(sender)
        print("Failed to resolve service \(sender.name): \(errorDict)")
    }
}
