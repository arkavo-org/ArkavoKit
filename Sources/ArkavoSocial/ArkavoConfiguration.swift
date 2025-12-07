import Foundation

/// Centralized configuration for Arkavo identity and authentication services.
/// All three apps (Arkavo, ArkavoCreator, HYPERforum) use this shared configuration.
public struct ArkavoConfiguration: Sendable {
    public static let shared = ArkavoConfiguration()

    /// Identity server URL for WebAuthn authentication
    public let identityURL = URL(string: "https://identity.arkavo.net")!

    /// WebAuthn relying party identifier
    public let relyingPartyID = "identity.arkavo.net"

    /// WebSocket server URL for real-time communication
    public let websocketURL = URL(string: "wss://100.arkavo.net/ws")!

    /// Domains for certificate pinning
    public let pinnedDomains: Set<String> = ["identity.arkavo.net", "kas.arkavo.net", "app.arkavo.com"]

    private init() {}

    /// Generate OAuth redirect URL for a specific service
    /// - Parameters:
    ///   - service: The OAuth provider (e.g., "twitch", "patreon")
    ///   - client: The client app identifier (default: "arkavocreator")
    /// - Returns: The full redirect URL string
    public func oauthRedirectURL(for service: String, client: String = "arkavocreator") -> String {
        "https://identity.arkavo.net/oauth/\(client)/\(service)"
    }
}
