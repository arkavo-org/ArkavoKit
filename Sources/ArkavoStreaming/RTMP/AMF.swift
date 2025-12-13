import Foundation

/// AMF0 (Action Message Format) encoder/decoder for RTMP
///
/// Implements AMF0 data encoding used in RTMP command messages.
public struct AMF0: Sendable {

    // MARK: - Data Types

    public enum DataType: UInt8 {
        case number = 0x00
        case boolean = 0x01
        case string = 0x02
        case object = 0x03
        case null = 0x05
        case undefined = 0x06
        case array = 0x08
        case objectEnd = 0x09
        case strictArray = 0x0A
        case date = 0x0B
        case longString = 0x0C
    }

    // MARK: - Encoding

    /// Encode a number value
    public static func encodeNumber(_ value: Double) -> Data {
        var data = Data()
        data.append(DataType.number.rawValue)
        var bigEndianValue = value.bitPattern.bigEndian
        data.append(Data(bytes: &bigEndianValue, count: 8))
        return data
    }

    /// Encode a boolean value
    public static func encodeBool(_ value: Bool) -> Data {
        var data = Data()
        data.append(DataType.boolean.rawValue)
        data.append(value ? 0x01 : 0x00)
        return data
    }

    /// Encode a string value
    public static func encodeString(_ value: String) -> Data {
        var data = Data()
        let stringData = value.data(using: .utf8) ?? Data()
        let length = UInt16(stringData.count)

        if length > UInt16.max {
            // Use long string
            data.append(DataType.longString.rawValue)
            var longLength = UInt32(stringData.count).bigEndian
            data.append(Data(bytes: &longLength, count: 4))
        } else {
            // Use regular string
            data.append(DataType.string.rawValue)
            var shortLength = length.bigEndian
            data.append(Data(bytes: &shortLength, count: 2))
        }

        data.append(stringData)
        return data
    }

    /// Encode a null value
    public static func encodeNull() -> Data {
        return Data([DataType.null.rawValue])
    }

    /// Encode an object (key-value pairs)
    public static func encodeObject(_ object: [String: AMFValue]) -> Data {
        var data = Data()
        data.append(DataType.object.rawValue)

        for (key, value) in object {
            // Property name (without type marker, just length + string)
            let keyData = key.data(using: .utf8) ?? Data()
            var keyLength = UInt16(keyData.count).bigEndian
            data.append(Data(bytes: &keyLength, count: 2))
            data.append(keyData)

            // Property value
            data.append(value.encode())
        }

        // Object end marker
        data.append(contentsOf: [0x00, 0x00, DataType.objectEnd.rawValue])

        return data
    }

    /// Encode an array
    public static func encodeArray(_ array: [AMFValue]) -> Data {
        var data = Data()
        data.append(DataType.strictArray.rawValue)

        var count = UInt32(array.count).bigEndian
        data.append(Data(bytes: &count, count: 4))

        for value in array {
            data.append(value.encode())
        }

        return data
    }

    // MARK: - Value Type

    public enum AMFValue: Sendable {
        case number(Double)
        case boolean(Bool)
        case string(String)
        case null
        case object([String: AMFValue])
        case array([AMFValue])

        func encode() -> Data {
            switch self {
            case .number(let value):
                return AMF0.encodeNumber(value)
            case .boolean(let value):
                return AMF0.encodeBool(value)
            case .string(let value):
                return AMF0.encodeString(value)
            case .null:
                return AMF0.encodeNull()
            case .object(let value):
                return AMF0.encodeObject(value)
            case .array(let value):
                return AMF0.encodeArray(value)
            }
        }
    }

    // MARK: - RTMP Commands

    /// Create RTMP connect command for publishing
    /// Following OBS's publisher connect format (not player format)
    public static func createConnectCommand(
        app: String,
        flashVer: String = "ArkavoCreator/1.0 (compatible; FMLE/3.0)",
        tcUrl: String,
        objectEncoding: Double = 0.0
    ) -> Data {
        var data = Data()

        // Command name: "connect"
        data.append(encodeString("connect"))

        // Transaction ID: 1
        data.append(encodeNumber(1.0))

        // Command object (publisher format - simpler than player format)
        // OBS uses: app, type, flashVer, swfUrl, tcUrl, objectEncoding
        let commandObject: [String: AMFValue] = [
            "app": .string(app),
            "type": .string("nonprivate"),  // Required for publishing
            "flashVer": .string(flashVer),
            "tcUrl": .string(tcUrl),
            "objectEncoding": .number(objectEncoding)
        ]
        data.append(encodeObject(commandObject))

        return data
    }

    /// Create RTMP createStream command
    public static func createCreateStreamCommand(transactionId: Double = 2.0) -> Data {
        var data = Data()

        // Command name: "createStream"
        data.append(encodeString("createStream"))

        // Transaction ID
        data.append(encodeNumber(transactionId))

        // Command object: null
        data.append(encodeNull())

        return data
    }

    /// Create RTMP publish command
    public static func createPublishCommand(
        streamName: String,
        publishingName: String = "live",
        transactionId: Double = 0.0
    ) -> Data {
        var data = Data()

        // Command name: "publish"
        data.append(encodeString("publish"))

        // Transaction ID
        data.append(encodeNumber(transactionId))

        // Command object: null
        data.append(encodeNull())

        // Publishing name
        data.append(encodeString(streamName))

        // Publishing type
        data.append(encodeString(publishingName))

        return data
    }

    /// Create RTMP releaseStream command
    public static func createReleaseStreamCommand(streamName: String, transactionId: Double = 2.0) -> Data {
        var data = Data()

        // Command name: "releaseStream"
        data.append(encodeString("releaseStream"))

        // Transaction ID
        data.append(encodeNumber(transactionId))

        // Command object: null
        data.append(encodeNull())

        // Stream name
        data.append(encodeString(streamName))

        return data
    }

    /// Create RTMP FCPublish command
    public static func createFCPublishCommand(streamName: String, transactionId: Double = 3.0) -> Data {
        var data = Data()

        // Command name: "FCPublish"
        data.append(encodeString("FCPublish"))

        // Transaction ID
        data.append(encodeNumber(transactionId))

        // Command object: null
        data.append(encodeNull())

        // Stream name
        data.append(encodeString(streamName))

        return data
    }

    public static func createFCUnpublishCommand(streamName: String, transactionId: Double) -> Data {
        var data = Data()

        // Command name: "FCUnpublish"
        data.append(encodeString("FCUnpublish"))

        // Transaction ID
        data.append(encodeNumber(transactionId))

        // Command object: null
        data.append(encodeNull())

        // Stream name
        data.append(encodeString(streamName))

        return data
    }

    public static func createDeleteStreamCommand(streamId: UInt32, transactionId: Double) -> Data {
        var data = Data()

        // Command name: "deleteStream"
        data.append(encodeString("deleteStream"))

        // Transaction ID
        data.append(encodeNumber(transactionId))

        // Command object: null
        data.append(encodeNull())

        // Stream ID
        data.append(encodeNumber(Double(streamId)))

        return data
    }
}
