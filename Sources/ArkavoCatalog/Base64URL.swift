import Foundation

/// RFC 4648 §5 base64url, in the one form catalog v2 uses for every binary value: the alphabet
/// `A–Z a–z 0–9 - _`, no `=`, and canonical, so `encode(decode(text)) == text`. A length that is 1 more than a multiple of
/// 4 and non-zero trailing bits are therefore refused, as the node's `URL_SAFE_NO_PAD` refuses them.
public enum Base64URL {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    /// The bytes `text` encodes, or nil when it is not canonical unpadded base64url. The empty text is empty data.
    public static func decode(_ text: String) -> Data? {
        let input = Array(text.utf8)
        guard input.count % 4 != 1 else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(input.count * 3 / 4)
        var accumulator: UInt32 = 0
        var bits = 0
        for character in input {
            guard let value = value(of: character) else { return nil }
            accumulator = accumulator << 6 | UInt32(value)
            bits += 6
            if bits >= 8 {
                bits -= 8
                output.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)))
                accumulator &= (1 << UInt32(bits)) - 1
            }
        }
        // What is left are the unused trailing bits of the last character; they must be zero.
        guard accumulator == 0 else { return nil }
        return Data(output)
    }

    public static func encode(_ data: Data) -> String {
        var output: [UInt8] = []
        output.reserveCapacity((data.count * 4 + 2) / 3)
        var accumulator: UInt32 = 0
        var bits = 0
        for byte in data {
            accumulator = accumulator << 8 | UInt32(byte)
            bits += 8
            while bits >= 6 {
                bits -= 6
                output.append(alphabet[Int(accumulator >> UInt32(bits)) & 0x3F])
            }
            accumulator &= (1 << UInt32(bits)) - 1
        }
        if bits > 0 { output.append(alphabet[Int(accumulator << UInt32(6 - bits)) & 0x3F]) }
        return String(decoding: output, as: UTF8.self)
    }

    private static func value(of character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): character - UInt8(ascii: "A")
        case UInt8(ascii: "a")...UInt8(ascii: "z"): character - UInt8(ascii: "a") + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0") + 52
        case UInt8(ascii: "-"): 62
        case UInt8(ascii: "_"): 63
        default: nil
        }
    }
}
