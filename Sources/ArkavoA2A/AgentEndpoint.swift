import Foundation

/// Represents an A2A agent endpoint
public struct AgentEndpoint: Codable, Identifiable, Hashable, Sendable {
    /// Unique identifier for the agent
    public let id: String

    /// WebSocket URL for the agent (ws:// or wss://)
    public let url: String

    /// Agent's public key (optional, for mTLS)
    public let publicKey: String?

    /// Agent metadata
    public let metadata: AgentMetadata

    public init(id: String, url: String, publicKey: String? = nil, metadata: AgentMetadata) {
        self.id = id
        self.url = url
        self.publicKey = publicKey
        self.metadata = metadata
    }

    /// The host component from the URL
    public var host: String? {
        URL(string: url)?.host
    }

    /// The port component from the URL
    public var port: Int? {
        URL(string: url)?.port
    }

    /// Whether this endpoint uses TLS
    public var usesTLS: Bool {
        url.hasPrefix("wss://")
    }
}

/// Metadata about an agent discovered via mDNS
public struct AgentMetadata: Codable, Hashable, Sendable {
    /// Human-readable name for the agent
    public let name: String

    /// Purpose or description of the agent
    public let purpose: String

    /// LLM model the agent is using
    public let model: String

    /// Additional properties from mDNS TXT record
    public let properties: [String: String]

    public init(name: String, purpose: String, model: String, properties: [String: String] = [:]) {
        self.name = name
        self.purpose = purpose
        self.model = model
        self.properties = properties
    }
}
