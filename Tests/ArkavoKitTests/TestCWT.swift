import Foundation

/// Hand-encoded Arkavo CWTs for tests: tag61(tag18([bstr(protected), {},
/// bstr(claims), bstr(signature)])), unpadded base64url. The signature is
/// junk; `CWTSubject` does not verify it.
enum TestCWT {
    /// claims map: {1: "identity.arkavo.net", 2: sub}
    static func token(sub: String) -> String {
        let claims: [UInt8] = [0xA2, 0x01] + tstr("identity.arkavo.net") + [0x02] + tstr(sub)
        return wrap(claims: claims)
    }

    /// A claims map with an issuer and no `sub`.
    static func tokenWithoutSub() -> String {
        wrap(claims: [0xA1, 0x01] + tstr("identity.arkavo.net"))
    }

    static func wrap(claims: [UInt8]) -> String {
        let cose: [UInt8] = [0x84] + bstr([0xA1, 0x01, 0x26]) + [0xA0] + bstr(claims) + bstr([0x00, 0x01])
        return base64URL([0xD8, 0x3D, 0xD2] + cose) // tag 61, tag 18
    }

    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A text string, with a one-byte length from 24 bytes (an account UUID is 36).
    static func tstr(_ s: String) -> [UInt8] {
        let b = Array(s.utf8)
        precondition(b.count < 256, "fixture strings stay under 256 bytes")
        return b.count < 24 ? [0x60 + UInt8(b.count)] + b : [0x78, UInt8(b.count)] + b
    }

    static func bstr(_ b: [UInt8]) -> [UInt8] {
        precondition(b.count < 256, "fixture byte strings stay under 256 bytes")
        return b.count < 24 ? [0x40 + UInt8(b.count)] + b : [0x58, UInt8(b.count)] + b
    }
}
