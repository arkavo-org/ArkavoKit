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

    // MARK: - Limits

    /// Maximum allowed nesting depth for objects/arrays to prevent stack overflow on crafted input.
    static let maxDepth = 32

    // MARK: - AMF0 Type Markers

    private enum Marker: UInt8 {
        case number = 0x00        // Double precision IEEE-754
        case boolean = 0x01       // Boolean value
        case string = 0x02        // UTF-8 string (16-bit length)
        case object = 0x03        // Object with properties
        case null = 0x05          // Null value
        case undefined = 0x06     // Undefined value
        case reference = 0x07     // Reference (16-bit index)
        case array = 0x08         // ECMA array
        case objectEnd = 0x09     // Object end marker (0x00 0x00 0x09)
        case strictArray = 0x0A   // Strict array
        case date = 0x0B          // Date (double ms + int16 tz offset)
        case longString = 0x0C    // Long UTF-8 string (32-bit length)
        case unsupported = 0x0D   // Unsupported marker
        case xmlDocument = 0x0F   // XML document (same wire format as longString)
        case typedObject = 0x10   // Typed object (class name + object properties)
    }

    // MARK: - AMF0 Value Types

    /// Represents an AMF0 value
    enum Value: Equatable {
        case number(Double)
        case boolean(Bool)
        case string(String)
        case object([String: Value])
        case array([Value])
        case date(Double)
        case reference(UInt16)
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
        case maxDepthExceeded
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
            case .maxDepthExceeded:
                return "Maximum AMF0 nesting depth (\(AMF0Parser.maxDepth)) exceeded"
            case .malformedData(let reason):
                return "Malformed AMF0 data: \(reason)"
            }
        }
    }

    // MARK: - Properties

    private let data: Data
    private var offset: Int
    private var depth: Int = 0

    // MARK: - Initialization

    /// Create a parser for the given AMF0-encoded data
    /// - Parameter data: AMF0-encoded binary data (slices with non-zero startIndex are normalized)
    init(data: Data) {
        self.data = data.startIndex == 0 ? data : Data(data)
        self.offset = 0
    }

    /// Create a parser starting at a specific offset
    /// - Parameters:
    ///   - data: AMF0-encoded binary data (slices with non-zero startIndex are normalized)
    ///   - offset: Starting offset relative to the start of `data`
    init(data: Data, offset: Int) {
        let normalized = data.startIndex == 0 ? data : Data(data)
        self.data = normalized
        self.offset = max(0, min(offset, normalized.count))
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
            // ECMA arrays have string keys like objects (e.g., onMetaData)
            return try .object(readECMAArray())
        case .strictArray:
            return try .array(readStrictArray())
        case .reference:
            return try .reference(readReference())
        case .date:
            return try .date(readDate())
        case .longString, .xmlDocument:
            return try .string(readLongString())
        case .typedObject:
            return try .object(readTypedObject())
        case .null:
            return .null
        case .undefined, .unsupported:
            return .undefined
        case .objectEnd:
            throw ParseError.unexpectedEndOfObject
        }
    }

    /// Read a number (Double) without reading the marker
    /// - Returns: The parsed number
    /// - Throws: ParseError if data is insufficient
    mutating func readNumber() throws -> Double {
        guard bytesRemaining >= 8 else {
            throw ParseError.insufficientData(need: 8, have: bytesRemaining)
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
        guard bytesRemaining >= 1 else {
            throw ParseError.insufficientData(need: 1, have: bytesRemaining)
        }

        let value = data[offset] != 0
        offset += 1
        return value
    }

    /// Read a 16-bit reference index without reading the marker
    mutating func readReference() throws -> UInt16 {
        guard bytesRemaining >= 2 else {
            throw ParseError.insufficientData(need: 2, have: bytesRemaining)
        }

        let index = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        offset += 2
        return index
    }

    /// Read an AMF0 Date (8-byte IEEE-754 ms timestamp + 2-byte timezone offset) without reading the marker
    mutating func readDate() throws -> Double {
        guard bytesRemaining >= 10 else {
            throw ParseError.insufficientData(need: 10, have: bytesRemaining)
        }
        let milliseconds = try readNumber()
        // Consume 2-byte reserved/timezone offset
        offset += 2
        return milliseconds
    }

    /// Read a UTF-8 string (16-bit length) without reading the marker
    /// - Returns: The parsed string
    /// - Throws: ParseError if data is insufficient or string is invalid
    mutating func readString() throws -> String {
        guard bytesRemaining >= 2 else {
            throw ParseError.insufficientData(need: 2, have: bytesRemaining)
        }

        // Read 16-bit length (big endian)
        let length = Int(data[offset]) << 8 | Int(data[offset + 1])
        offset += 2

        guard length <= bytesRemaining else {
            throw ParseError.insufficientData(need: length, have: bytesRemaining)
        }

        let stringData = data.subdata(in: offset..<(offset + length))
        offset += length

        guard let string = String(data: stringData, encoding: .utf8) else {
            throw ParseError.invalidString(offset: offset - length)
        }

        return string
    }

    /// Read a long UTF-8 string or XML document (32-bit length) without reading the marker
    mutating func readLongString() throws -> String {
        guard bytesRemaining >= 4 else {
            throw ParseError.insufficientData(need: 4, have: bytesRemaining)
        }

        let lengthU32 = UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 |
                        UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
        offset += 4

        guard let length = Int(exactly: lengthU32), length <= bytesRemaining else {
            throw ParseError.insufficientData(
                need: Int(min(UInt64(lengthU32), UInt64(Int.max))),
                have: bytesRemaining
            )
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
        guard depth < Self.maxDepth else {
            throw ParseError.maxDepthExceeded
        }
        depth += 1
        defer { depth -= 1 }

        var properties: [String: Value] = [:]

        while true {
            // Check for object end marker (0x00 0x00 0x09)
            guard bytesRemaining >= 3 else {
                throw ParseError.insufficientData(need: 3, have: bytesRemaining)
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

    /// Read a typed object (class name + object properties) without reading the marker
    mutating func readTypedObject() throws -> [String: Value] {
        _ = try readString() // Class name
        return try readObject()
    }

    /// Read an ECMA array without reading the marker
    /// - Returns: The parsed object (ECMA arrays have string keys, not numeric indices)
    /// - Throws: ParseError if data is malformed
    mutating func readECMAArray() throws -> [String: Value] {
        // ECMA arrays start with a 32-bit count hint (terminated by object end marker)
        guard bytesRemaining >= 4 else {
            throw ParseError.insufficientData(need: 4, have: bytesRemaining)
        }
        let count = UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 |
                    UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
        offset += 4
        print("🔍 [AMF0] Reading ECMA array with count: \(count)")

        // ECMA arrays are essentially objects with string keys (like onMetaData)
        let obj = try readObject()
        print("🔍 [AMF0] ECMA array keys: \(obj.keys.sorted())")
        return obj
    }

    /// Read a strict array without reading the marker
    /// - Returns: The parsed array
    /// - Throws: ParseError if data is malformed
    mutating func readStrictArray() throws -> [Value] {
        guard depth < Self.maxDepth else {
            throw ParseError.maxDepthExceeded
        }
        depth += 1
        defer { depth -= 1 }

        // Read 32-bit count
        guard bytesRemaining >= 4 else {
            throw ParseError.insufficientData(need: 4, have: bytesRemaining)
        }

        let countU32 = UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 |
                       UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
        offset += 4

        // Each AMF0 element occupies at least 1 byte, so count cannot exceed bytesRemaining.
        guard let count = Int(exactly: countU32), count >= 0, count <= bytesRemaining else {
            throw ParseError.insufficientData(
                need: Int(min(UInt64(countU32), UInt64(Int.max))),
                have: bytesRemaining
            )
        }

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
        guard depth < Self.maxDepth else {
            throw ParseError.maxDepthExceeded
        }
        depth += 1
        defer { depth -= 1 }

        while true {
            // Check for object end marker
            guard bytesRemaining >= 3 else {
                throw ParseError.insufficientData(need: 3, have: bytesRemaining)
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
        guard count >= 0 else {
            throw ParseError.malformedData("Negative value count: \(count)")
        }
        guard count <= bytesRemaining else {
            throw ParseError.insufficientData(need: count, have: bytesRemaining)
        }

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
