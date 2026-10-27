import Foundation

/// One JSON value (RFC 8259) parsed strictly: UTF-8 with no byte-order mark, one value and nothing after it, at most
/// `maxDepth` nested arrays and objects, and no object that repeats a key, since a parser that keeps the first of two
/// equal keys and one that keeps the last would read different documents. Keys are compared after their
/// escapes are decoded. Numbers keep their text, so `1`, `1.0` and `1e0` are different values. It prints and reflects
/// as a fixed text, so no value reaches a log.
indirect enum StrictJSON: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case object([String: StrictJSON])
    case array([StrictJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    /// A guard against unbounded recursion, not an import limit: a TDF manifest nests about five deep.
    static let maxDepth = 32

    static func parse(_ data: Data) -> StrictJSON? {
        let bytes = [UInt8](data)
        guard String(validating: bytes, as: UTF8.self) != nil else { return nil }
        var parser = Parser(bytes: bytes)
        guard let value = parser.value(depth: 0) else { return nil }
        parser.skipWhitespace()
        return parser.index == bytes.count ? value : nil
    }

    var description: String { "Strict JSON value" }
    var debugDescription: String { "Strict JSON value" }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }

    var object: [String: StrictJSON]? {
        if case .object(let value) = self { value } else { nil }
    }

    var array: [StrictJSON]? {
        if case .array(let value) = self { value } else { nil }
    }

    var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) -> StrictJSON? {
            skipWhitespace()
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"): return object(depth: depth + 1)
            case UInt8(ascii: "["): return array(depth: depth + 1)
            case UInt8(ascii: "\""): return string().map(StrictJSON.string)
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return number()
            default: return nil
            }
        }

        private mutating func object(depth: Int) -> StrictJSON? {
            guard depth <= StrictJSON.maxDepth else { return nil }
            index += 1
            var members: [String: StrictJSON] = [:]
            skipWhitespace()
            if consume(UInt8(ascii: "}")) { return .object(members) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = string() else { return nil }
                skipWhitespace()
                guard consume(UInt8(ascii: ":")), let member = value(depth: depth), members[key] == nil else {
                    return nil
                }
                members[key] = member
                skipWhitespace()
                if consume(UInt8(ascii: "}")) { return .object(members) }
                guard consume(UInt8(ascii: ",")) else { return nil }
            }
        }

        private mutating func array(depth: Int) -> StrictJSON? {
            guard depth <= StrictJSON.maxDepth else { return nil }
            index += 1
            var elements: [StrictJSON] = []
            skipWhitespace()
            if consume(UInt8(ascii: "]")) { return .array(elements) }
            while true {
                guard let element = value(depth: depth) else { return nil }
                elements.append(element)
                skipWhitespace()
                if consume(UInt8(ascii: "]")) { return .array(elements) }
                guard consume(UInt8(ascii: ",")) else { return nil }
            }
        }

        /// From the opening quote. The document is valid UTF-8, so the bytes between escapes are copied as they are.
        private mutating func string() -> String? {
            index += 1
            var utf8: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""): return String(decoding: utf8, as: UTF8.self)
                case 0x00..<0x20: return nil
                case UInt8(ascii: "\\"):
                    guard let scalar = escape() else { return nil }
                    utf8.append(contentsOf: String(scalar).utf8)
                default: utf8.append(byte)
                }
            }
            return nil
        }

        /// After a backslash: one escape, with a `\u` surrogate pair joined; a lone surrogate is refused.
        private mutating func escape() -> Unicode.Scalar? {
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): return Unicode.Scalar(byte)
            case UInt8(ascii: "b"): return "\u{08}"
            case UInt8(ascii: "f"): return "\u{0C}"
            case UInt8(ascii: "n"): return "\n"
            case UInt8(ascii: "r"): return "\r"
            case UInt8(ascii: "t"): return "\t"
            case UInt8(ascii: "u"):
                guard let unit = hex4() else { return nil }
                switch unit {
                case 0xD800...0xDBFF:
                    guard consume(UInt8(ascii: "\\")), consume(UInt8(ascii: "u")), let low = hex4(),
                          (0xDC00...0xDFFF).contains(low) else { return nil }
                    return Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
                case 0xDC00...0xDFFF: return nil
                default: return Unicode.Scalar(unit)
                }
            default: return nil
            }
        }

        private mutating func hex4() -> UInt32? {
            guard bytes.count - index >= 4 else { return nil }
            var value: UInt32 = 0
            for byte in bytes[index..<index + 4] {
                guard let digit = Self.hexDigit(byte) else { return nil }
                value = value << 4 | digit
            }
            index += 4
            return value
        }

        static func hexDigit(_ byte: UInt8) -> UInt32? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): UInt32(byte - UInt8(ascii: "A") + 10)
            default: nil
            }
        }

        /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`, kept as written.
        private mutating func number() -> StrictJSON? {
            let start = index
            _ = consume(UInt8(ascii: "-"))
            if consume(UInt8(ascii: "0")) {
                guard !isDigit() else { return nil }
            } else {
                guard digits() else { return nil }
            }
            if consume(UInt8(ascii: ".")) { guard digits() else { return nil } }
            if consume(UInt8(ascii: "e")) || consume(UInt8(ascii: "E")) {
                _ = consume(UInt8(ascii: "+")) || consume(UInt8(ascii: "-"))
                guard digits() else { return nil }
            }
            return .number(String(decoding: bytes[start..<index], as: UTF8.self))
        }

        private func isDigit() -> Bool {
            index < bytes.count && (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index])
        }

        /// One or more digits.
        private mutating func digits() -> Bool {
            let start = index
            while isDigit() { index += 1 }
            return index > start
        }

        private mutating func literal(_ word: String, _ value: StrictJSON) -> StrictJSON? {
            let expected = Array(word.utf8)
            guard bytes.count - index >= expected.count, bytes[index..<index + expected.count].elementsEqual(expected)
            else { return nil }
            index += expected.count
            return value
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
    }
}
