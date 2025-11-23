import Foundation

/// AMF0 (Action Message Format 0) Parser for RTMP protocol
///
/// Parses AMF0-encoded data used in RTMP command messages and responses.
/// AMF0 is a binary format for serializing ActionScript objects.
///
/// ## References
/// - [AMF0 Specification](https://rtmp.veriskope.com/pdf/amf0-file-format-specification.pdf)
/// - RTMP Specification Section 3.1.1.2
struct AMF0Parser {

    // MARK: - AMF0 Type Markers

    private enum Marker: UInt8 {
        case number = 0x00        // Double precision IEEE-754
        case boolean = 0x01       // Boolean value
        case string = 0x02        // UTF-8 string
        case object = 0x03        // Object with properties
        case null = 0x05          // Null value
        case undefined = 0x06     // Undefined value
        case objectEnd = 0x09     // Object end marker (0x00 0x00 0x09)
        case array = 0x08         // ECMA array
        case strictArray = 0x0A   // Strict array
    }

    // MARK: - AMF0 Value Types

    /// Represents an AMF0 value
    enum Value: Equatable {
        case number(Double)
        case boolean(Bool)
        case string(String)
        case object([String: Value])
        case array([Value])
        case null
        case undefined

        /// Get the value as a Double if it's a number
        var numberValue: Double? {
            if case .number(let value) = self {
                return value
            }
            return nil
        }

        /// Get the value as a String if it's a string
        var stringValue: String? {
            if case .string(let value) = self {
                return value
            }
            return nil
        }

        /// Get the value as a Bool if it's a boolean
        var boolValue: Bool? {
            if case .boolean(let value) = self {
                return value
            }
            return nil
        }

        /// Get the value as an object dictionary if it's an object
        var objectValue: [String: Value]? {
            if case .object(let value) = self {
                return value
            }
            return nil
        }

        /// Get the value as an array if it's an array
        var arrayValue: [Value]? {
            if case .array(let value) = self {
                return value
            }
            return nil
        }
    }

    // MARK: - Parser Errors

    enum ParseError: Error, CustomStringConvertible {
        case insufficientData(need: Int, have: Int)
        case invalidMarker(UInt8)
        case invalidString(offset: Int)
        case unexpectedEndOfObject
        case malformedData(String)

        var description: String {
            switch self {
            case .insufficientData(let need, let have):
                return "Insufficient data: need \(need) bytes, have \(have)"
            case .invalidMarker(let marker):
                return "Invalid AMF0 marker: 0x\(String(format: "%02X", marker))"
            case .invalidString(let offset):
                return "Invalid UTF-8 string at offset \(offset)"
            case .unexpectedEndOfObject:
                return "Unexpected end of object"
            case .malformedData(let reason):
                return "Malformed AMF0 data: \(reason)"
            }
        }
    }

    // MARK: - Properties

    private let data: Data
    private var offset: Int

    // MARK: - Initialization

    /// Create a parser for the given AMF0-encoded data
    /// - Parameter data: AMF0-encoded binary data
    init(data: Data) {
        self.data = data
        self.offset = 0
    }

    /// Create a parser starting at a specific offset
    /// - Parameters:
    ///   - data: AMF0-encoded binary data
    ///   - offset: Starting offset in the data
    init(data: Data, offset: Int) {
        self.data = data
        self.offset = offset
    }

    // MARK: - Public Parsing Methods

    /// Current offset in the data
    var currentOffset: Int {
        return offset
    }

    /// Bytes remaining in the data
    var bytesRemaining: Int {
        return data.count - offset
    }

    /// Read the next AMF0 value
    /// - Returns: The parsed AMF0 value
    /// - Throws: ParseError if data is invalid or insufficient
    mutating func readValue() throws -> Value {
        guard offset < data.count else {
            throw ParseError.insufficientData(need: 1, have: 0)
        }

        let marker = data[offset]
        offset += 1

        guard let type = Marker(rawValue: marker) else {
            throw ParseError.invalidMarker(marker)
        }

        switch type {
        case .number:
            return try .number(readNumber())
        case .boolean:
            return try .boolean(readBoolean())
        case .string:
            return try .string(readString())
        case .object:
            return try .object(readObject())
        case .array:
            return try .array(readECMAArray())
        case .strictArray:
            return try .array(readStrictArray())
        case .null:
            return .null
        case .undefined:
            return .undefined
        case .objectEnd:
            throw ParseError.unexpectedEndOfObject
        }
    }

    /// Read a number (Double) without reading the marker
    /// - Returns: The parsed number
    /// - Throws: ParseError if data is insufficient
    mutating func readNumber() throws -> Double {
        guard offset + 8 <= data.count else {
            throw ParseError.insufficientData(need: 8, have: data.count - offset)
        }

        var bits: UInt64 = 0
        for i in 0..<8 {
            bits = (bits << 8) | UInt64(data[offset + i])
        }
        offset += 8

        return Double(bitPattern: bits)
    }

    /// Read a boolean without reading the marker
    /// - Returns: The parsed boolean
    /// - Throws: ParseError if data is insufficient
    mutating func readBoolean() throws -> Bool {
        guard offset + 1 <= data.count else {
            throw ParseError.insufficientData(need: 1, have: data.count - offset)
        }

        let value = data[offset] != 0
        offset += 1
        return value
    }

    /// Read a UTF-8 string without reading the marker
    /// - Returns: The parsed string
    /// - Throws: ParseError if data is insufficient or string is invalid
    mutating func readString() throws -> String {
        guard offset + 2 <= data.count else {
            throw ParseError.insufficientData(need: 2, have: data.count - offset)
        }

        // Read 16-bit length (big endian)
        let length = Int(data[offset]) << 8 | Int(data[offset + 1])
        offset += 2

        guard offset + length <= data.count else {
            throw ParseError.insufficientData(need: length, have: data.count - offset)
        }

        let stringData = data.subdata(in: offset..<(offset + length))
        offset += length

        guard let string = String(data: stringData, encoding: .utf8) else {
            throw ParseError.invalidString(offset: offset - length)
        }

        return string
    }

    /// Read an object (dictionary) without reading the marker
    /// - Returns: The parsed object as a dictionary
    /// - Throws: ParseError if data is malformed
    mutating func readObject() throws -> [String: Value] {
        var properties: [String: Value] = [:]

        while true {
            // Check for object end marker (0x00 0x00 0x09)
            guard offset + 3 <= data.count else {
                throw ParseError.insufficientData(need: 3, have: data.count - offset)
            }

            // Check if we hit the end marker
            if data[offset] == 0x00 && data[offset + 1] == 0x00 && data[offset + 2] == 0x09 {
                offset += 3
                break
            }

            // Read property name (UTF-8 string without marker)
            let propertyName = try readString()

            // Read property value
            let propertyValue = try readValue()

            properties[propertyName] = propertyValue
        }

        return properties
    }

    /// Read an ECMA array without reading the marker
    /// - Returns: The parsed array
    /// - Throws: ParseError if data is malformed
    mutating func readECMAArray() throws -> [Value] {
        // ECMA arrays start with a 32-bit count (usually ignored)
        guard offset + 4 <= data.count else {
            throw ParseError.insufficientData(need: 4, have: data.count - offset)
        }
        offset += 4  // Skip the count

        // ECMA arrays are essentially objects with numeric keys
        // For simplicity, we'll read as object and extract values
        let obj = try readObject()

        // Convert to array (assuming keys are sequential numbers starting from 0)
        let sortedKeys = obj.keys.compactMap { Int($0) }.sorted()
        return sortedKeys.map { obj[String($0)]! }
    }

    /// Read a strict array without reading the marker
    /// - Returns: The parsed array
    /// - Throws: ParseError if data is malformed
    mutating func readStrictArray() throws -> [Value] {
        // Read 32-bit count
        guard offset + 4 <= data.count else {
            throw ParseError.insufficientData(need: 4, have: data.count - offset)
        }

        let count = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 |
                    Int(data[offset + 2]) << 8 | Int(data[offset + 3])
        offset += 4

        var values: [Value] = []
        values.reserveCapacity(count)

        for _ in 0..<count {
            values.append(try readValue())
        }

        return values
    }

    /// Skip the next AMF0 value without parsing it fully
    /// - Throws: ParseError if data is insufficient
    mutating func skipValue() throws {
        _ = try readValue()  // Simple implementation - just read and discard
    }

    /// Skip an object without parsing property values
    /// - Throws: ParseError if data is insufficient
    mutating func skipObject() throws {
        while true {
            // Check for object end marker
            guard offset + 3 <= data.count else {
                throw ParseError.insufficientData(need: 3, have: data.count - offset)
            }

            if data[offset] == 0x00 && data[offset + 1] == 0x00 && data[offset + 2] == 0x09 {
                offset += 3
                break
            }

            // Skip property name
            _ = try readString()

            // Skip property value
            try skipValue()
        }
    }

    // MARK: - Convenience Methods

    /// Read multiple values in sequence
    /// - Parameter count: Number of values to read
    /// - Returns: Array of parsed values
    /// - Throws: ParseError if any value fails to parse
    mutating func readValues(count: Int) throws -> [Value] {
        var values: [Value] = []
        values.reserveCapacity(count)

        for _ in 0..<count {
            values.append(try readValue())
        }

        return values
    }

    /// Read all remaining values
    /// - Returns: Array of all parsed values
    /// - Throws: ParseError if any value fails to parse
    mutating func readAllValues() throws -> [Value] {
        var values: [Value] = []

        while offset < data.count {
            values.append(try readValue())
        }

        return values
    }
}
