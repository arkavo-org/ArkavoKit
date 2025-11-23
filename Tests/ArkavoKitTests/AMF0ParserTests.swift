import XCTest
@testable import ArkavoStreaming

final class AMF0ParserTests: XCTestCase {

    // MARK: - Number Tests

    func testReadNumber() throws {
        // AMF0 number is IEEE-754 double (8 bytes, big endian)
        // Example: 1.0 = 0x3FF0000000000000
        let data = Data([0x00, 0x3F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        var parser = AMF0Parser(data: data)

        let value = try parser.readValue()
        XCTAssertEqual(value, .number(1.0))
    }

    func testReadNegativeNumber() throws {
        // -42.5 = 0xC045400000000000
        let data = Data([0x00, 0xC0, 0x45, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00])
        var parser = AMF0Parser(data: data)

        let value = try parser.readValue()
        XCTAssertEqual(value, .number(-42.5))
    }

    func testReadZero() throws {
        // 0.0 = 0x0000000000000000
        let data = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        var parser = AMF0Parser(data: data)

        let value = try parser.readValue()
        XCTAssertEqual(value, .number(0.0))
    }

    // MARK: - Boolean Tests

    func testReadBooleanTrue() throws {
        let data = Data([0x01, 0x01])  // marker + true
        var parser = AMF0Parser(data: data)

        let value = try parser.readValue()
        XCTAssertEqual(value, .boolean(true))
    }

    func testReadBooleanFalse() throws {
        let data = Data([0x01, 0x00])  // marker + false
        var parser = AMF0Parser(data: data)

        let value = try parser.readValue()
        XCTAssertEqual(value, .boolean(false))
    }

    // MARK: - String Tests

    func testReadString() throws {
        // "test" = length(0x0004) + "test"
        let data = Data([0x02, 0x00, 0x04]) + "test".data(using: .utf8)!
        var parser = AMF0Parser(data: data)

        let value = try parser.readValue()
        XCTAssertEqual(value, .string("test"))
    }

    func testReadEmptyString() throws {
        let data = Data([0x02, 0x00, 0x00])  // marker + length 0
        var parser = AMF0Parser(data: data)

        let value = try parser.readValue()
        XCTAssertEqual(value, .string(""))
    }

    func testReadLongString() throws {
        let longString = String(repeating: "a", count: 1000)
        var data = Data([0x02])  // string marker
        let length = UInt16(longString.count)
        data.append(UInt8(length >> 8))
        data.append(UInt8(length & 0xFF))
        data.append(longString.data(using: .utf8)!)

        var parser = AMF0Parser(data: data)

        let value = try parser.readValue()
        XCTAssertEqual(value, .string(longString))
    }

    func testReadUTF8String() throws {
        // Test with emoji
        let emoji = "👋🌍"
        let emojiData = emoji.data(using: .utf8)!
        let length = UInt16(emojiData.count)

        var data = Data([0x02])  // string marker
        data.append(UInt8(length >> 8))
        data.append(UInt8(length & 0xFF))
        data.append(emojiData)

        var parser = AMF0Parser(data: data)

        let value = try parser.readValue()
        XCTAssertEqual(value, .string(emoji))
    }

    // MARK: - Null and Undefined Tests

    func testReadNull() throws {
        let data = Data([0x05])  // null marker
        var parser = AMF0Parser(data: data)

        let value = try parser.readValue()
        XCTAssertEqual(value, .null)
    }

    func testReadUndefined() throws {
        let data = Data([0x06])  // undefined marker
        var parser = AMF0Parser(data: data)

        let value = try parser.readValue()
        XCTAssertEqual(value, .undefined)
    }

    // MARK: - Object Tests

    func testReadEmptyObject() throws {
        // Empty object: marker + end marker (0x00 0x00 0x09)
        let data = Data([0x03, 0x00, 0x00, 0x09])
        var parser = AMF0Parser(data: data)

        let value = try parser.readValue()
        guard case .object(let dict) = value else {
            XCTFail("Expected object")
            return
        }
        XCTAssertTrue(dict.isEmpty)
    }

    func testReadObjectWithStringProperty() throws {
        // Object with one property: { "name": "value" }
        var data = Data([0x03])  // object marker

        // Property name "name" (length 4)
        data.append(contentsOf: [0x00, 0x04])
        data.append("name".data(using: .utf8)!)

        // Property value "value" (string marker + length 5)
        data.append(0x02)  // string marker
        data.append(contentsOf: [0x00, 0x05])
        data.append("value".data(using: .utf8)!)

        // Object end marker
        data.append(contentsOf: [0x00, 0x00, 0x09])

        var parser = AMF0Parser(data: data)

        let value = try parser.readValue()
        guard case .object(let dict) = value else {
            XCTFail("Expected object")
            return
        }
        XCTAssertEqual(dict.count, 1)
        XCTAssertEqual(dict["name"], .string("value"))
    }

    func testReadObjectWithMultipleProperties() throws {
        // Object with { "count": 42.0, "flag": true }
        var data = Data([0x03])  // object marker

        // Property "count" = 42.0
        data.append(contentsOf: [0x00, 0x05])  // name length
        data.append("count".data(using: .utf8)!)
        data.append(0x00)  // number marker
        data.append(contentsOf: [0x40, 0x45, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])  // 42.0

        // Property "flag" = true
        data.append(contentsOf: [0x00, 0x04])  // name length
        data.append("flag".data(using: .utf8)!)
        data.append(0x01)  // boolean marker
        data.append(0x01)  // true

        // Object end marker
        data.append(contentsOf: [0x00, 0x00, 0x09])

        var parser = AMF0Parser(data: data)

        let value = try parser.readValue()
        guard case .object(let dict) = value else {
            XCTFail("Expected object")
            return
        }
        XCTAssertEqual(dict.count, 2)
        XCTAssertEqual(dict["count"], .number(42.0))
        XCTAssertEqual(dict["flag"], .boolean(true))
    }

    // MARK: - Array Tests

    func testReadStrictArray() throws {
        // Strict array with [1.0, 2.0]
        var data = Data([0x0A])  // strict array marker

        // Array count (2)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x02])

        // Element 1: 1.0
        data.append(0x00)  // number marker
        data.append(contentsOf: [0x3F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        // Element 2: 2.0
        data.append(0x00)  // number marker
        data.append(contentsOf: [0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        var parser = AMF0Parser(data: data)

        let value = try parser.readValue()
        guard case .array(let arr) = value else {
            XCTFail("Expected array")
            return
        }
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr[0], .number(1.0))
        XCTAssertEqual(arr[1], .number(2.0))
    }

    func testReadEmptyStrictArray() throws {
        // Strict array with 0 elements
        let data = Data([0x0A, 0x00, 0x00, 0x00, 0x00])
        var parser = AMF0Parser(data: data)

        let value = try parser.readValue()
        guard case .array(let arr) = value else {
            XCTFail("Expected array")
            return
        }
        XCTAssertTrue(arr.isEmpty)
    }

    // MARK: - Multiple Values Tests

    func testReadMultipleValues() throws {
        // String "hello" + Number 5.0 + Boolean true
        var data = Data()

        // String "hello"
        data.append(0x02)
        data.append(contentsOf: [0x00, 0x05])
        data.append("hello".data(using: .utf8)!)

        // Number 5.0
        data.append(0x00)
        data.append(contentsOf: [0x40, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        // Boolean true
        data.append(0x01)
        data.append(0x01)

        var parser = AMF0Parser(data: data)

        let values = try parser.readValues(count: 3)
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values[0], .string("hello"))
        XCTAssertEqual(values[1], .number(5.0))
        XCTAssertEqual(values[2], .boolean(true))
    }

    func testReadAllValues() throws {
        // Number 1.0 + String "test" + Null
        var data = Data()

        data.append(0x00)
        data.append(contentsOf: [0x3F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        data.append(0x02)
        data.append(contentsOf: [0x00, 0x04])
        data.append("test".data(using: .utf8)!)

        data.append(0x05)

        var parser = AMF0Parser(data: data)

        let values = try parser.readAllValues()
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values[0], .number(1.0))
        XCTAssertEqual(values[1], .string("test"))
        XCTAssertEqual(values[2], .null)
    }

    // MARK: - Skip Tests

    func testSkipObject() throws {
        // Object { "x": 1.0 } followed by string "after"
        var data = Data([0x03])

        data.append(contentsOf: [0x00, 0x01])
        data.append("x".data(using: .utf8)!)
        data.append(0x00)
        data.append(contentsOf: [0x3F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        data.append(contentsOf: [0x00, 0x00, 0x09])

        data.append(0x02)
        data.append(contentsOf: [0x00, 0x05])
        data.append("after".data(using: .utf8)!)

        var parser = AMF0Parser(data: data)

        try parser.skipValue()  // Skip the object
        let value = try parser.readValue()
        XCTAssertEqual(value, .string("after"))
    }

    // MARK: - Convenience Property Tests

    func testValueProperties() {
        XCTAssertEqual(AMF0Parser.Value.number(42.0).numberValue, 42.0)
        XCTAssertNil(AMF0Parser.Value.string("test").numberValue)

        XCTAssertEqual(AMF0Parser.Value.string("hello").stringValue, "hello")
        XCTAssertNil(AMF0Parser.Value.number(1.0).stringValue)

        XCTAssertEqual(AMF0Parser.Value.boolean(true).boolValue, true)
        XCTAssertNil(AMF0Parser.Value.string("test").boolValue)

        let dict = ["key": AMF0Parser.Value.string("value")]
        XCTAssertEqual(AMF0Parser.Value.object(dict).objectValue, dict)
        XCTAssertNil(AMF0Parser.Value.string("test").objectValue)

        let arr = [AMF0Parser.Value.number(1.0)]
        XCTAssertEqual(AMF0Parser.Value.array(arr).arrayValue, arr)
        XCTAssertNil(AMF0Parser.Value.string("test").arrayValue)
    }

    // MARK: - Error Tests

    func testInsufficientDataError() {
        let data = Data([0x00, 0x3F, 0xF0])  // Number marker but incomplete data
        var parser = AMF0Parser(data: data)

        XCTAssertThrowsError(try parser.readValue()) { error in
            guard case AMF0Parser.ParseError.insufficientData = error else {
                XCTFail("Expected insufficientData error")
                return
            }
        }
    }

    func testInvalidMarkerError() {
        let data = Data([0xFF])  // Invalid marker
        var parser = AMF0Parser(data: data)

        XCTAssertThrowsError(try parser.readValue()) { error in
            guard case AMF0Parser.ParseError.invalidMarker = error else {
                XCTFail("Expected invalidMarker error")
                return
            }
        }
    }

    func testInvalidUTF8Error() {
        // String with invalid UTF-8
        var data = Data([0x02, 0x00, 0x02])  // String marker + length 2
        data.append(contentsOf: [0xFF, 0xFE])  // Invalid UTF-8 bytes

        var parser = AMF0Parser(data: data)

        XCTAssertThrowsError(try parser.readValue()) { error in
            guard case AMF0Parser.ParseError.invalidString = error else {
                XCTFail("Expected invalidString error")
                return
            }
        }
    }

    // MARK: - Real World RTMP Examples

    func testRTMPConnectResponse() throws {
        // Simulates "_result" transaction 1.0 response
        var data = Data()

        // "_result" string
        data.append(0x02)
        data.append(contentsOf: [0x00, 0x07])
        data.append("_result".data(using: .utf8)!)

        // Transaction ID: 1.0
        data.append(0x00)
        data.append(contentsOf: [0x3F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        // Null (command object)
        data.append(0x05)

        var parser = AMF0Parser(data: data)

        let command = try parser.readValue()
        XCTAssertEqual(command, .string("_result"))

        let txnId = try parser.readValue()
        XCTAssertEqual(txnId.numberValue, 1.0)

        let cmdObj = try parser.readValue()
        XCTAssertEqual(cmdObj, .null)
    }

    func testRTMPCreateStreamResponse() throws {
        // Simulates createStream response with stream ID 1.0
        var data = Data()

        // "_result" string
        data.append(0x02)
        data.append(contentsOf: [0x00, 0x07])
        data.append("_result".data(using: .utf8)!)

        // Transaction ID: 4.0
        data.append(0x00)
        data.append(contentsOf: [0x40, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        // Null (command object)
        data.append(0x05)

        // Stream ID: 1.0
        data.append(0x00)
        data.append(contentsOf: [0x3F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        var parser = AMF0Parser(data: data)

        let command = try parser.readValue()
        XCTAssertEqual(command.stringValue, "_result")

        let txnId = try parser.readValue()
        XCTAssertEqual(txnId.numberValue, 4.0)

        // Skip command object
        try parser.skipValue()

        let streamId = try parser.readValue()
        XCTAssertEqual(streamId.numberValue, 1.0)
    }

    // MARK: - Parser State Tests

    func testBytesRemaining() {
        let data = Data([0x05, 0x05, 0x05])  // 3 null values
        var parser = AMF0Parser(data: data)

        XCTAssertEqual(parser.bytesRemaining, 3)

        _ = try? parser.readValue()
        XCTAssertEqual(parser.bytesRemaining, 2)

        _ = try? parser.readValue()
        XCTAssertEqual(parser.bytesRemaining, 1)

        _ = try? parser.readValue()
        XCTAssertEqual(parser.bytesRemaining, 0)
    }

    func testCurrentOffset() {
        let data = Data([0x05, 0x05])  // 2 null values
        var parser = AMF0Parser(data: data)

        XCTAssertEqual(parser.currentOffset, 0)

        _ = try? parser.readValue()
        XCTAssertEqual(parser.currentOffset, 1)

        _ = try? parser.readValue()
        XCTAssertEqual(parser.currentOffset, 2)
    }

    func testInitWithOffset() throws {
        let data = Data([0xFF, 0x05, 0x02, 0x00, 0x02]) + "hi".data(using: .utf8)!
        var parser = AMF0Parser(data: data, offset: 1)  // Skip first byte

        let value1 = try parser.readValue()
        XCTAssertEqual(value1, .null)

        let value2 = try parser.readValue()
        XCTAssertEqual(value2, .string("hi"))
    }
}
