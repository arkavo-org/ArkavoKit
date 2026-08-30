import Foundation
import ArkavoSocial

/// A JSON-RPC 2.0 notification from an A2A agent (no id field)
public struct AgentNotification: Codable, Sendable {
    /// JSON-RPC version (always "2.0")
    public let jsonrpc: String

    /// The notification method name
    public let method: String

    /// Notification parameters
    public let params: AnyCodable

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case method
        case params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        self.method = try container.decode(String.self, forKey: .method)
        self.params = try container.decode(AnyCodable.self, forKey: .params)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(method, forKey: .method)
        try container.encode(params, forKey: .params)
    }
}

/// Callback protocol for handling notifications
@MainActor
public protocol AgentNotificationHandler: AnyObject, Sendable {
    /// Called when a notification is received from the agent
    func handleNotification(method: String, params: AnyCodable) async
}
