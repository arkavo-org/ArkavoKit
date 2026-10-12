import Security
import XCTest
@testable import ArkavoSocial

/// `swift test` has no keychain entitlement (every call returns -34018), so the
/// Secure Enclave round trip is checked in the Creator test host. This pins the
/// query shape: the bug was a `String` tag where creation and lookup use `Data`.
final class DIDKeyDeletionQueryTests: XCTestCase {
    func testDeletionQueryTagIsTheUTF8DataOfTheDIDKeyTag() {
        let query = KeychainManager.didKeyDeletionQuery()
        let tag = query[kSecAttrApplicationTag as String]
        XCTAssertTrue(tag is Data, "a String tag never matches a key created with a Data tag")
        XCTAssertEqual(tag as? Data, Data("com.arkavo.did".utf8))
    }

    func testDeletionQueryNamesAnECKey() {
        let query = KeychainManager.didKeyDeletionQuery()
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassKey as String)
        XCTAssertEqual(query[kSecAttrKeyType as String] as? String, kSecAttrKeyTypeECSECPrimeRandom as String)
    }
}
