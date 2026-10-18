import Foundation

/// Reads the `sub` claim (key 2) of an Arkavo CWT bearer token: unpadded
/// base64url, CBOR tag 61 → COSE_Sign1 tag 18 → a 4-array whose third element
/// is the claims map as a byte string.
///
/// The signature is NOT verified: the server is the verifier. The callers only
/// need to know which account a token names (its `sub`, an account UUID):
/// account deletion scopes its sign-in to the stored token's `sub`, checks the
/// fresh token's against it, and compares the two before removing the stored
/// one; `connect(account:)` reuses a cached session only when its token's `sub`
/// is `account`. Ported from Creator's `ArkavoCreator/Patreon/CWTSubject.swift`
/// (subject only).
enum CWTSubject {
    static func sub(fromToken token: String) -> String? {
        var b64 = token.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        var r = Reader(bytes: [UInt8](data))
        r.skipTag(61); r.skipTag(18)
        guard let arrayCount = r.readArrayHeader(), arrayCount == 4,
              r.skipItem(),
              r.skipItem(),
              let claims = r.readByteString()
        else { return nil }
        var c = Reader(bytes: claims)
        guard let pairs = c.readMapHeader() else { return nil }
        for _ in 0 ..< pairs {
            let savedIndex = c.i
            if let key = c.readUInt() {
                if key == 2 { return c.readTextString() }
                guard c.skipItem() else { return nil }
            } else {
                c.i = savedIndex
                guard c.skipItem() else { return nil }
                guard c.skipItem() else { return nil }
            }
        }
        return nil
    }

    private struct Reader {
        /// Containers nested deeper than this make the token unreadable, so a
        /// hostile token cannot recurse until the stack overflows.
        static let maxDepth = 16

        var bytes: [UInt8]
        var i = 0

        mutating func next() -> UInt8? {
            guard i < bytes.count else { return nil }
            defer { i += 1 }
            return bytes[i]
        }

        /// Reads a CBOR head; returns (majorType, argumentValue).
        mutating func readHead() -> (UInt8, UInt64)? {
            guard let b = next() else { return nil }
            let major = b >> 5, info = b & 0x1F
            switch info {
            case 0 ... 23: return (major, UInt64(info))
            case 24 ... 27:
                let n = 1 << (Int(info) - 24)
                var v: UInt64 = 0
                for _ in 0 ..< n {
                    guard let x = next() else { return nil }
                    v = v << 8 | UInt64(x)
                }
                return (major, v)
            default: return nil
            }
        }

        mutating func skipTag(_ tag: UInt64) {
            let save = i
            if let (m, v) = readHead(), m == 6, v == tag { return }
            i = save
        }

        /// Bytes after the cursor (`i <= bytes.count` always holds).
        private var remaining: UInt64 { UInt64(bytes.count) - UInt64(i) }

        // Every count and length is checked against `remaining` as a UInt64
        // before it is narrowed to Int, so an 8-byte length cannot trap.

        mutating func readArrayHeader() -> Int? {
            guard let (m, v) = readHead(), m == 4, v <= remaining else { return nil }
            return Int(v)
        }

        mutating func readMapHeader() -> Int? {
            guard let (m, v) = readHead(), m == 5, v <= remaining else { return nil }
            return Int(v)
        }

        mutating func readByteString() -> [UInt8]? {
            guard let (m, v) = readHead(), m == 2, v <= remaining else { return nil }
            let n = Int(v)
            defer { i += n }
            return Array(bytes[i ..< i + n])
        }

        mutating func readTextString() -> String? {
            guard let (m, v) = readHead(), m == 3, v <= remaining else { return nil }
            let n = Int(v)
            defer { i += n }
            return String(bytes: bytes[i ..< i + n], encoding: .utf8)
        }

        mutating func readUInt() -> UInt64? {
            guard let (m, v) = readHead(), m == 0 else { return nil }
            return v
        }

        /// Skips one complete data item (recursively for containers, to at
        /// most `maxDepth` levels).
        mutating func skipItem(depth: Int = 0) -> Bool {
            guard depth <= Self.maxDepth, let (m, v) = readHead() else { return false }
            switch m {
            case 0, 1, 7: return true
            case 2, 3:
                guard v <= remaining else { return false }
                i += Int(v)
                return true
            case 4:
                for _ in 0 ..< v {
                    guard skipItem(depth: depth + 1) else { return false }
                }
                return true
            case 5:
                // Key and value per pair, without forming `v * 2` (which could overflow).
                var pairsLeft = v
                while pairsLeft > 0 {
                    guard skipItem(depth: depth + 1), skipItem(depth: depth + 1) else { return false }
                    pairsLeft -= 1
                }
                return true
            case 6: return skipItem(depth: depth + 1)
            default: return false
            }
        }
    }
}
