import Foundation

/// The keychain items `ArkavoClient` reads to link an Apple identity and reads
/// and removes when it deletes an account.
///
/// Internal, and a test seam only: `swift test` has no keychain entitlement
/// (every call returns errSecMissingEntitlement, -34018), so tests inject an
/// in-memory store. The app always uses `KeychainCredentialStore`.
@MainActor
protocol AccountCredentialStore {
    /// The shared Arkavo session token (CWT), if any.
    func authenticationToken() -> String?
    /// The shared Arkavo handle saved by `connect`, if any.
    func sharedHandle() -> String?
    func deleteAuthenticationToken()
    /// The shared handle and the shared DID.
    func deleteSharedHandleAndDID()
    /// The app-local handle and DID pair.
    func deleteIdentityPair()
    /// The Secure Enclave DID key.
    func deleteDIDKey() throws
    /// The stored Apple user id, email and name.
    func deleteAppleAccount()
}

/// `AccountCredentialStore` over `KeychainManager`.
struct KeychainCredentialStore: AccountCredentialStore {
    func authenticationToken() -> String? { KeychainManager.getAuthenticationToken() }
    func sharedHandle() -> String? { KeychainManager.getArkavoHandle() }
    func deleteAuthenticationToken() { KeychainManager.deleteAuthenticationToken() }
    func deleteSharedHandleAndDID() { KeychainManager.deleteArkavoCredentials() }
    func deleteIdentityPair() { KeychainManager.deleteIdentityPair() }
    func deleteDIDKey() throws { try KeychainManager.deleteDIDKey() }
    func deleteAppleAccount() { KeychainManager.deleteAppleAccount() }
}
