import Foundation
import ArkavoSocial

/// Preserves JSON-RPC 2.0 identifier JSON type (string vs integer) across decode/encode round-trips.
enum JSONRPCID: Hashable, Sendable, Codable {
    case string(String)
    case int(Int)

    var stringValue: String {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        }
    }

    var intValue: Int? {
        switch self {
        case .string:
            return nil
        case .int(let value):
            return value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let stringId = try? container.decode(String.self) {
            self = .string(stringId)
        } else if let intId = try? container.decode(Int.self) {
            self = .int(intId)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCID.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected JSON-RPC id to be a String or Int"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        }
    }
}

/// A JSON-RPC 2.0 request to an A2A agent
public struct AgentRequest: Codable, Sendable {
    /// JSON-RPC version (always "2.0")
    public let jsonrpc: String

    /// The method name to invoke
    public let method: String

    /// Request parameters (can be array, object, or omitted/null)
    public let params: AnyCodable

    /// Unique request identifier
    public let id: String

    /// Preserved wire-level JSON-RPC ID type (numeric vs string)
    let rpcId: JSONRPCID

    var numericId: Int? {
        rpcId.intValue
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case method
        case params
        case id
    }

    public init(method: String, params: AnyCodable = AnyCodable(NSNull()), id: String = UUID().uuidString) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
        self.id = id
        self.rpcId = .string(id)
    }

    public init(method: String, params: AnyCodable = AnyCodable(NSNull()), numericId: Int) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
        self.id = String(numericId)
        self.rpcId = .int(numericId)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.jsonrpc = try container.decode(String.self, forKey: .jsonrpc)
        self.method = try container.decode(String.self, forKey: .method)
        self.params = try container.decodeIfPresent(AnyCodable.self, forKey: .params) ?? AnyCodable(NSNull())
        let decodedId = try container.decode(JSONRPCID.self, forKey: .id)
        self.rpcId = decodedId
        self.id = decodedId.stringValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(method, forKey: .method)
        if !(params.value is NSNull) {
            try container.encode(params, forKey: .params)
        }
        try container.encode(rpcId, forKey: .id)
    }
}

/// Wire-level wrapper around `AgentResponse` that preserves numeric vs string JSON-RPC `id` types
/// without breaking the public `AgentResponse` enum's associated value layout.
struct AgentResponseEnvelope: Codable, Sendable {
    let rpcId: JSONRPCID
    let response: AgentResponse

    init(response: AgentResponse, rpcId: JSONRPCID? = nil) {
        self.rpcId = rpcId ?? .string(response.id)
        self.response = response
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AgentResponse.CodingKeys.self)
        let decodedId = try container.decode(JSONRPCID.self, forKey: .id)
        self.rpcId = decodedId

        if container.contains(.error), !(try container.decodeNil(forKey: .error)) {
            let errorContainer = try container.nestedContainer(keyedBy: AgentResponse.ErrorKeys.self, forKey: .error)
            let code = try errorContainer.decode(Int.self, forKey: .code)
            let message = try errorContainer.decode(String.self, forKey: .message)
            self.response = .error(id: decodedId.stringValue, code: code, message: message)
        } else if container.contains(.result) {
            let result = try container.decode(AnyCodable.self, forKey: .result)
            self.response = .success(id: decodedId.stringValue, result: result)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Response must contain either 'result' or 'error'"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AgentResponse.CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        try container.encode(rpcId, forKey: .id)

        switch response {
        case .success(_, let result):
            try container.encode(result, forKey: .result)
        case .error(_, let code, let message):
            var errorContainer = container.nestedContainer(keyedBy: AgentResponse.ErrorKeys.self, forKey: .error)
            try errorContainer.encode(code, forKey: .code)
            try errorContainer.encode(message, forKey: .message)
        }
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
        let envelope = try AgentResponseEnvelope(from: decoder)
        self = envelope.response
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
