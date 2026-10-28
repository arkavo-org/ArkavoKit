import Foundation

// AnyCodable wrapper for handling dynamic JSON values
public struct AnyCodable: Codable, Sendable {
    // We'll use an enum to restrict possible values to Sendable types
    private enum Storage: Sendable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([AnyCodable])
        case dictionary([String: AnyCodable])
    }

    private let storage: Storage

    public var value: Any {
        switch storage {
        case .null:
            NSNull()
        case let .bool(value):
            value
        case let .int(value):
            value
        case let .double(value):
            value
        case let .string(value):
            value
        case let .array(value):
            value.map(\.value)
        case let .dictionary(value):
            value.mapValues(\.value)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            storage = .null
        } else if let bool = try? container.decode(Bool.self) {
            storage = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            storage = .int(int)
        } else if let double = try? container.decode(Double.self) {
            storage = .double(double)
        } else if let string = try? container.decode(String.self) {
            storage = .string(string)
        } else if let array = try? container.decode([AnyCodable].self) {
            storage = .array(array)
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            storage = .dictionary(dictionary)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable cannot decode value",
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch storage {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .dictionary(value):
            try container.encode(value)
        }
    }

    public init(_ value: Any) {
        switch value {
        case is NSNull:
            storage = .null
        case let bool as Bool:
            storage = .bool(bool)
        case let int as Int:
            storage = .int(int)
        case let double as Double:
            storage = .double(double)
        case let string as String:
            storage = .string(string)
        case let array as [Any]:
            storage = .array(array.map(AnyCodable.init))
        case let dictionary as [String: Any]:
            storage = .dictionary(dictionary.mapValues(AnyCodable.init))
        default:
            storage = .null // Default to null for unsupported types
        }
    }
}

