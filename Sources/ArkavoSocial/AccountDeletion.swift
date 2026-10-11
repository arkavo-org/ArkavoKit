import Foundation

/// The server's acknowledgement of an account deletion (`DELETE /account` → 202).
public struct AccountDeletionReceipt: Sendable, Equatable {
    /// Names the deletion to the server's status endpoint, which takes no other
    /// credential. A bearer secret: never log it or show it.
    public let deletionID: String
    /// When the server accepted the deletion. The account stopped existing then.
    public let requestedAt: Date
    /// When the server promises to have removed everything bound to the account.
    public let completesBy: Date

    public init(deletionID: String, requestedAt: Date, completesBy: Date) {
        self.deletionID = deletionID
        self.requestedAt = requestedAt
        self.completesBy = completesBy
    }
}

/// How `ArkavoClient.deleteAccount(accountName:)` ended.
public enum AccountDeletionResult: Sendable, Equatable {
    /// The server accepted the deletion. The receipt is nil when a 2xx body did
    /// not decode; the deletion still counts, because the server accepted it.
    case deleted(AccountDeletionReceipt?)
    /// The passkey sign-in found no such account: it was already deleted.
    case alreadyDeleted
}

extension AccountDeletionReceipt {
    /// Decodes a `DELETE /account` 2xx body. authnz-rs (`account::DeletionStatus`)
    /// sends `{deletion_id, status, requested_at, completes_by}` with the times
    /// as Unix seconds. nil when the body does not have that shape.
    static func decode(_ data: Data) -> AccountDeletionReceipt? {
        struct Body: Decodable {
            let deletion_id: String
            let requested_at: Double
            let completes_by: Double
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        return AccountDeletionReceipt(
            deletionID: body.deletion_id,
            requestedAt: Date(timeIntervalSince1970: body.requested_at),
            completesBy: Date(timeIntervalSince1970: body.completes_by)
        )
    }
}
