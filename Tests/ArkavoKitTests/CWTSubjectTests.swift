import XCTest
@testable import ArkavoSocial

final class CWTSubjectTests: XCTestCase {
    func testExtractsSubClaim() {
        XCTAssertEqual(CWTSubject.sub(fromToken: TestCWT.token(sub: "arkavo:abc-123")), "arkavo:abc-123")
    }

    func testMissingSubIsNil() {
        XCTAssertNil(CWTSubject.sub(fromToken: TestCWT.tokenWithoutSub()))
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(CWTSubject.sub(fromToken: "not-a-cwt"))
        XCTAssertNil(CWTSubject.sub(fromToken: ""))
    }

    func testSkipsNonUIntClaimKeys() {
        // claims map: {-1: "x", 2: "arkavo:me"} — a negative key precedes sub
        let claims: [UInt8] = [0xA2, 0x20] + TestCWT.tstr("x") + [0x02] + TestCWT.tstr("arkavo:me")
        XCTAssertEqual(CWTSubject.sub(fromToken: TestCWT.wrap(claims: claims)), "arkavo:me")
    }

    /// Malformed tokens with oversized 8-byte lengths or counts return nil and,
    /// the point of the test, do not trap. A trap kills the runner (SIGTRAP,
    /// exit 133) instead of failing an assertion.
    func testMalformedLengthsReturnNilWithoutCrashing() {
        let huge: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        // 1. Payload bstr with an 8-byte length of 2^64-1.
        XCTAssertNil(CWTSubject.sub(fromToken: TestCWT.base64URL(
            [0xD8, 0x3D, 0xD2, 0x84, 0x40, 0xA0, 0x5B] + huge + [0x41, 0x00])))
        // 2. Claims map with an 8-byte count of 2^64-1.
        let claimsMapHuge: [UInt8] = [0xBB] + huge
        XCTAssertNil(CWTSubject.sub(fromToken: TestCWT.base64URL(
            [0xD8, 0x3D, 0xD2, 0x84, 0x40, 0xA0, 0x40 + UInt8(claimsMapHuge.count)] + claimsMapHuge + [0x41, 0x00])))
        // 3. Unprotected map whose count would overflow `count * 2`.
        XCTAssertNil(CWTSubject.sub(fromToken: TestCWT.base64URL(
            [0xD8, 0x3D, 0xD2, 0x84, 0x40, 0xBB, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])))
        // 4. Outer array with an 8-byte count of 2^64-1.
        XCTAssertNil(CWTSubject.sub(fromToken: TestCWT.base64URL([0xD8, 0x3D, 0xD2, 0x9B] + huge)))
        // 5. A bstr claim key with an 8-byte length of 2^64-1.
        let claimsBadKey: [UInt8] = [0xA1, 0x5B] + huge + [0x00]
        XCTAssertNil(CWTSubject.sub(fromToken: TestCWT.base64URL(
            [0xD8, 0x3D, 0xD2, 0x84, 0x40, 0xA0, 0x40 + UInt8(claimsBadKey.count)] + claimsBadKey + [0x41, 0x00])))
    }

    /// A token nested far past the reader's depth limit returns nil instead of
    /// recursing until the stack overflows (which would kill the runner).
    func testDeeplyNestedItemReturnsNilWithoutCrashing() {
        // Unprotected header slot holds 100_000 nested single-element arrays.
        let nested = [UInt8](repeating: 0x81, count: 100_000) + [0x00]
        let bytes: [UInt8] = [0xD8, 0x3D, 0xD2, 0x84, 0x40] + nested + [0x40, 0x40]
        XCTAssertNil(CWTSubject.sub(fromToken: TestCWT.base64URL(bytes)))
    }
}
