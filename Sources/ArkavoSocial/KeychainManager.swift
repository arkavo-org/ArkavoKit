import Foundation

// MARK: - Keychain Manager

public class KeychainManager {
    private static let didKeyTag = "com.arkavo.did"

    /// Shared keychain access group for credential sharing across Arkavo apps.
    /// Uses com.arkavo.webauthn which is provisioned in all apps' keychain-access-groups.
    /// The Team ID prefix (AppIdentifierPrefix) must be included.
    public static let sharedAccessGroup = "M8GS7ZT95Y.com.arkavo.webauthn"

    enum KeychainError: Error {
        case duplicateItem
        case unknown(OSStatus)
        case itemNotFound
        case invalidHandle
    }

    public static func save(value: String, service: String, account: String, accessGroup: String? = nil) {
        do {
            try save(value.data(using: .utf8)!, service: service, account: account, accessGroup: accessGroup)
        } catch {
            // ignore, use save(data...) throws
        }
    }

    public static func save(_ data: Data, service: String, account: String, accessGroup: String? = nil) throws {
        var query: [String: AnyObject] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service as AnyObject,
            kSecAttrAccount as String: account as AnyObject,
            kSecValueData as String: data as AnyObject,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true as AnyObject,
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup as AnyObject
        }

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            let attributes: [String: AnyObject] = [
                kSecValueData as String: data as AnyObject,
            ]

            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else {
                throw KeychainError.unknown(status)
            }
        } else if status != errSecSuccess {
            throw KeychainError.unknown(status)
        }
    }

    public static func load(service: String, account: String, accessGroup: String? = nil) throws -> Data {
        var query: [String: AnyObject] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service as AnyObject,
            kSecAttrAccount as String: account as AnyObject,
            kSecReturnData as String: kCFBooleanTrue,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true as AnyObject,
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup as AnyObject
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unknown(status)
        }

        guard let data = result as? Data else {
            throw KeychainError.itemNotFound
        }

        return data
    }

    public static func getValue(service: String, account: String, accessGroup: String? = nil) -> String? {
        do {
            let data = try load(service: service, account: account, accessGroup: accessGroup)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    public static func delete(service: String, account: String, accessGroup: String? = nil) throws {
        var query: [String: AnyObject] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service as AnyObject,
            kSecAttrAccount as String: account as AnyObject,
            kSecUseDataProtectionKeychain as String: true as AnyObject,
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup as AnyObject
        }

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unknown(status)
        }
    }

    // MARK: - Token Management Convenience Methods

    static func getAccessToken() -> String? {
        do {
            let data = try load(service: "com.arkavo.patreon", account: "access_token")
            return String(data: data, encoding: .utf8)
        } catch {
            //            print("Error retrieving access token:", error)
            return nil
        }
    }

    static func getRefreshToken() -> String? {
        do {
            let data = try load(service: "com.arkavo.patreon", account: "refresh_token")
            return String(data: data, encoding: .utf8)
        } catch {
            //            print("Error retrieving refresh token:", error)
            return nil
        }
    }

    static func saveTokens(accessToken: String, refreshToken: String) throws {
        try save(accessToken.data(using: .utf8)!,
                 service: "com.arkavo.patreon",
                 account: "access_token")
        try save(refreshToken.data(using: .utf8)!,
                 service: "com.arkavo.patreon",
                 account: "refresh_token")
    }

    static func deleteTokens() {
        try? delete(service: "com.arkavo.patreon", account: "access_token")
        try? delete(service: "com.arkavo.patreon", account: "refresh_token")
        try? delete(service: "com.arkavo.patreon", account: "campaign_id")
    }

    public static func saveCampaignId(_ campaignId: String) throws {
        try save(campaignId.data(using: .utf8)!,
                 service: "com.arkavo.patreon",
                 account: "campaign_id")
    }

    public static func getCampaignId() -> String? {
        do {
            let data = try load(service: "com.arkavo.patreon", account: "campaign_id")
            return String(data: data, encoding: .utf8)
        } catch {
            print("Error retrieving campaign ID:", error)
            return nil
        }
    }

    static func deleteTokensAndCampaignId() {
        try? delete(service: "com.arkavo.patreon", account: "access_token")
        try? delete(service: "com.arkavo.patreon", account: "refresh_token")
        try? delete(service: "com.arkavo.patreon", account: "campaign_id")
    }

    static func saveBlueskyTokens(accessToken: String, refreshToken: String) throws {
        try save(accessToken.data(using: .utf8)!,
                 service: "com.arkavo.bluesky",
                 account: "access_token")
        try save(refreshToken.data(using: .utf8)!,
                 service: "com.arkavo.bluesky",
                 account: "refresh_token")
    }

    static func getBlueskyAccessToken() -> String? {
        do {
            let data = try load(service: "com.arkavo.bluesky", account: "access_token")
            return String(data: data, encoding: .utf8)
        } catch {
            //            print("Error retrieving access token:", error)
            return nil
        }
    }

    static func saveBlueskyHandle(_ handle: String) throws {
        try save(handle.data(using: .utf8)!,
                 service: "com.arkavo.bluesky",
                 account: "handle")
    }

    static func getBlueskyRefreshToken() -> String? {
        do {
            let data = try load(service: "com.arkavo.bluesky", account: "refresh_token")
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    static func getBlueskyHandle() -> String? {
        do {
            let data = try load(service: "com.arkavo.bluesky", account: "handle")
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    static func saveBlueskyDID(_ did: String) throws {
        try save(did.data(using: .utf8)!,
                 service: "com.arkavo.bluesky",
                 account: "did")
    }

    static func getBlueskyHDID() -> String? {
        do {
            let data = try load(service: "com.arkavo.bluesky", account: "did")
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    static func deleteBlueskyTokens() {
        try? delete(service: "com.arkavo.bluesky", account: "access_token")
        try? delete(service: "com.arkavo.bluesky", account: "refresh_token")
        try? delete(service: "com.arkavo.bluesky", account: "handle")
    }

    // MARK: - Shared Arkavo Authentication (shared across all Arkavo apps)

    public static func saveAuthenticationToken(_ token: String) throws {
        try save(token.data(using: .utf8)!,
                 service: "com.arkavo.webauthn",
                 account: "authentication_token",
                 accessGroup: sharedAccessGroup)
    }

    public static func getAuthenticationToken() -> String? {
        do {
            let data = try load(service: "com.arkavo.webauthn",
                               account: "authentication_token",
                               accessGroup: sharedAccessGroup)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    public static func deleteAuthenticationToken() {
        try? delete(service: "com.arkavo.webauthn",
                   account: "authentication_token",
                   accessGroup: sharedAccessGroup)
    }
}

public extension KeychainManager {
    // DID and Handle pair management
    static func saveHandle(_ handle: String) throws {
        guard !handle.isEmpty else {
            throw KeychainError.invalidHandle
        }
        try save(handle.data(using: .utf8)!,
                 service: "com.arkavo.identity",
                 account: "handle")
    }

    static func getHandle() -> String? {
        do {
            let data = try load(service: "com.arkavo.identity", account: "handle")
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    static func saveIdentityPair(handle: String, did: String) throws {
        // Save handle first
        try saveHandle(handle)
        // Then save DID using existing method
        try save(did.data(using: .utf8)!,
                 service: "com.arkavo.identity",
                 account: "did")
    }

    static func getIdentityPair() -> (handle: String, did: String)? {
        guard let handle = getHandle(),
              let did = getDID()
        else {
            return nil
        }
        return (handle: handle, did: did)
    }

    static func getDID() -> String? {
        do {
            let data = try load(service: "com.arkavo.identity", account: "did")
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    static func deleteIdentityPair() {
        try? delete(service: "com.arkavo.identity", account: "handle")
        try? delete(service: "com.arkavo.identity", account: "did")
    }

    // MARK: - DID Key Management

    internal enum DIDKeyError: Error {
        case accessControlCreationFailed
        case keyGenerationFailed(OSStatus)
        case invalidPublicKey
        case signatureCreationFailed
        case keyNotFound
    }

    internal static func generateAndSaveDIDKey() throws -> String {
        // First check if key already exists
        if let (_, _, did) = try? getDIDKey() {
            return did
        }

        // Create access control
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage],
            nil,
        ) else {
            throw DIDKeyError.accessControlCreationFailed
        }

        // Define private key attributes separately
        let privateKeyAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: didKeyTag.data(using: .utf8)!,
            kSecAttrAccessControl as String: accessControl,
        ]

        // Define key generation attributes
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: privateKeyAttributes,
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let err = error?.takeRetainedValue() {
                // Convert CFError code to OSStatus
                let code = OSStatus(err._code)
                throw DIDKeyError.keyGenerationFailed(code)
            }
            throw DIDKeyError.keyGenerationFailed(errSecParam)
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw DIDKeyError.invalidPublicKey
        }

        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error?.takeRetainedValue() ?? DIDKeyError.keyGenerationFailed(0)
        }

        // Generate DID using base58 encoding of the public key
        return "did:key:z" + publicKeyData.base58String
    }

    internal static func getDIDKey() throws -> (privateKey: SecKey, publicKey: SecKey, did: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: didKeyTag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            throw DIDKeyError.keyNotFound
        }

        let privateKey = result as! SecKey

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw DIDKeyError.invalidPublicKey
        }

        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error?.takeRetainedValue() ?? DIDKeyError.keyGenerationFailed(0)
        }

        let did = "did:key:z" + publicKeyData.base58String

        return (privateKey, publicKey, did)
    }

    internal static func signWithDIDKey(message: Data) throws -> Data {
        let (privateKey, _, _) = try getDIDKey()

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            message as CFData,
            &error,
        ) as Data? else {
            throw error?.takeRetainedValue() ?? DIDKeyError.signatureCreationFailed
        }

        return signature
    }

    internal static func verifyDIDSignature(message: Data, signature: Data) throws -> Bool {
        let (_, publicKey, _) = try getDIDKey()

        var error: Unmanaged<CFError>?
        let result = SecKeyVerifySignature(
            publicKey,
            .ecdsaSignatureMessageX962SHA256,
            message as CFData,
            signature as CFData,
            &error,
        )

        if let error = error?.takeRetainedValue() {
            throw error
        }

        return result
    }

    internal static func deleteDIDKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: didKeyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unknown(status)
        }
    }

    // MARK: - Shared Arkavo Handle (shared across all Arkavo apps)

    static func saveArkavoHandle(_ handle: String) throws {
        try save(handle.data(using: .utf8)!,
                 service: "com.arkavo.handle",
                 account: "arkavo",
                 accessGroup: sharedAccessGroup)
    }

    static func getArkavoHandle() -> String? {
        do {
            let data = try load(service: "com.arkavo.handle",
                                account: "arkavo",
                                accessGroup: sharedAccessGroup)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - Shared Arkavo DID (shared across all Arkavo apps)

    static func saveArkavoDID(_ did: String) throws {
        try save(did.data(using: .utf8)!,
                 service: "com.arkavo.did",
                 account: "arkavo",
                 accessGroup: sharedAccessGroup)
    }

    static func getArkavoDID() -> String? {
        do {
            let data = try load(service: "com.arkavo.did",
                                account: "arkavo",
                                accessGroup: sharedAccessGroup)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // Helper to save both at once (shared across all Arkavo apps)
    static func saveArkavoCredentials(handle: String, did: String) throws {
        try saveArkavoHandle(handle)
        try saveArkavoDID(did)
    }

    // Helper to get both at once (shared across all Arkavo apps)
    static func getArkavoCredentials() -> (handle: String, did: String)? {
        guard let handle = getArkavoHandle(),
              let did = getArkavoDID()
        else {
            return nil
        }
        return (handle: handle, did: did)
    }

    // Helper to delete both (shared across all Arkavo apps)
    static func deleteArkavoCredentials() {
        try? delete(service: "com.arkavo.handle", account: "arkavo", accessGroup: sharedAccessGroup)
        try? delete(service: "com.arkavo.did", account: "arkavo", accessGroup: sharedAccessGroup)
    }

    // MARK: - Stream Key Management

    /// Saves a stream key for a specific platform
    public static func saveStreamKey(_ streamKey: String, for platform: String) throws {
        let service = "com.arkavo.ArkavoCreator.\(platform.lowercased()).streamKey"
        try save(streamKey.data(using: .utf8)!,
                 service: service,
                 account: "streamKey")
    }

    /// Retrieves a stream key for a specific platform
    public static func getStreamKey(for platform: String) -> String? {
        let service = "com.arkavo.ArkavoCreator.\(platform.lowercased()).streamKey"
        return getValue(service: service, account: "streamKey")
    }

    /// Deletes a stream key for a specific platform
    public static func deleteStreamKey(for platform: String) {
        let service = "com.arkavo.ArkavoCreator.\(platform.lowercased()).streamKey"
        try? delete(service: service, account: "streamKey")
    }

    /// Saves a custom RTMP URL
    public static func saveCustomRTMPURL(_ url: String) throws {
        try save(url.data(using: .utf8)!,
                 service: "com.arkavo.ArkavoCreator.custom.rtmpURL",
                 account: "rtmpURL")
    }

    /// Retrieves the custom RTMP URL
    public static func getCustomRTMPURL() -> String? {
        return getValue(service: "com.arkavo.ArkavoCreator.custom.rtmpURL", account: "rtmpURL")
    }

    /// Deletes the custom RTMP URL
    public static func deleteCustomRTMPURL() {
        try? delete(service: "com.arkavo.ArkavoCreator.custom.rtmpURL", account: "rtmpURL")
    }
}

extension Data {
    var base58String: String {
        Base58.encode(Array(self))
    }
}

enum Base58 {
    private static let alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    private static let base = alphabet.count

    static func encode(_ bytes: [UInt8]) -> String {
        var bytes = bytes
        var zerosCount = 0

        for b in bytes {
            if b != 0 { break }
            zerosCount += 1
        }

        bytes.removeFirst(zerosCount)

        var result = [UInt8]()
        for b in bytes {
            var carry = Int(b)
            for j in 0 ..< result.count {
                carry += Int(result[j]) << 8
                result[j] = UInt8(carry % base)
                carry /= base
            }
            while carry > 0 {
                result.append(UInt8(carry % base))
                carry /= base
            }
        }

        let prefix = String(repeating: alphabet.first!, count: zerosCount)
        let encoded = result.reversed().map { alphabet[alphabet.index(alphabet.startIndex, offsetBy: Int($0))] }
        return prefix + String(encoded)
    }

    static func decode(_ string: String) -> [UInt8]? {
        var result = [UInt8]()
        for char in string {
            guard let charIndex = alphabet.firstIndex(of: char) else { return nil }
            let index = alphabet.distance(from: alphabet.startIndex, to: charIndex)

            var carry = index
            for j in 0 ..< result.count {
                carry += Int(result[j]) * base
                result[j] = UInt8(carry & 0xFF)
                carry >>= 8
            }

            while carry > 0 {
                result.append(UInt8(carry & 0xFF))
                carry >>= 8
            }
        }

        for char in string {
            if char != alphabet.first! { break }
            result.append(0)
        }

        return result.reversed()
    }
}
