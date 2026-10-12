import XCTest
@testable import ArkavoSocial

/// The deletion id is a bearer secret: no description of a receipt may carry it.
final class AccountDeletionReceiptDescriptionTests: XCTestCase {
    private let receipt = AccountDeletionReceipt(
        deletionID: "del-secret-123",
        requestedAt: Date(timeIntervalSince1970: 1_760_000_000),
        completesBy: Date(timeIntervalSince1970: 1_760_000_300)
    )

    func testDescriptionsRedactTheDeletionID() {
        for text in [
            String(describing: receipt),
            String(reflecting: receipt),
            "\(receipt)",
            String(describing: AccountDeletionResult.deleted(receipt)),
            String(reflecting: AccountDeletionResult.deleted(receipt)),
            String(describing: AccountDeletionResult.deleted(receipt) as AccountDeletionResult?),
        ] {
            XCTAssertFalse(text.contains("del-secret-123"), text)
        }
        XCTAssertTrue(String(describing: receipt).contains("<redacted>"))
        XCTAssertTrue(String(reflecting: receipt).contains("<redacted>"))
    }

    func testDescriptionKeepsTheTimes() {
        XCTAssertTrue(String(describing: receipt).hasPrefix("AccountDeletionReceipt(deletionID: <redacted>, requestedAt: "))
        XCTAssertTrue(String(describing: receipt).contains("completesBy: "))
    }

    func testAnUnequalReceiptStillDiffersByID() {
        let other = AccountDeletionReceipt(deletionID: "other", requestedAt: receipt.requestedAt, completesBy: receipt.completesBy)
        XCTAssertNotEqual(receipt, other)
    }
}
