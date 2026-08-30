import Foundation
import ArkavoSocial

/// A JSON-RPC 2.0 request to an A2A agent
public struct AgentRequest: Codable, Sendable {
    /// JSON-RPC version (always "2.0")
    public let jsonrpc: String

    /// The method name to invoke
    public let method: String

    /// Request parameters (can be array or object)
    public let params: AnyCodable

    /// Unique request identifier
    public let id: String

    public init(method: String, params: AnyCodable, id: String = UUID().uuidString) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
        self.id = id
    }
}

/// A JSON-RPC 2.0 response from an A2A agent
public enum AgentResponse: Codable, Sendable {
    case success(id: String, result: AnyCodable)
    case error(id: String, code: Int, message: String)

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case result
        case error
    }

    enum ErrorKeys: String, CodingKey {
        case code
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)

        if let result = try? container.decode(AnyCodable.self, forKey: .result) {
            self = .success(id: id, result: result)
        } else if container.contains(.error) {
            let errorContainer = try container.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error)
            let code = try errorContainer.decode(Int.self, forKey: .code)
            let message = try errorContainer.decode(String.self, forKey: .message)
            self = .error(id: id, code: code, message: message)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Response must contain either 'result' or 'error'"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)

        switch self {
        case .success(let id, let result):
            try container.encode(id, forKey: .id)
            try container.encode(result, forKey: .result)
        case .error(let id, let code, let message):
            try container.encode(id, forKey: .id)
            var errorContainer = container.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error)
            try errorContainer.encode(code, forKey: .code)
            try errorContainer.encode(message, forKey: .message)
        }
    }

    public var id: String {
        switch self {
        case .success(let id, _), .error(let id, _, _):
            return id
        }
    }

    public var isSuccess: Bool {
        switch self {
        case .success: return true
        case .error: return false
        }
    }
}

import Foundation
