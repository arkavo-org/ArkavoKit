import Foundation

/// Errors that can occur during A2A agent communication
public enum AgentError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case invalidEndpoint(String)
    case timeout(UInt64)
    case tlsError(String)
    case webSocketError(String)
    case invalidResponse(String)
    case jsonRpcError(code: Int, message: String)
    case discoveryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Transport not connected to any endpoint"
        case .connectionFailed(let details):
            return "Connection failed: \(details)"
        case .invalidEndpoint(let details):
            return "Invalid endpoint: \(details)"
        case .timeout(let ms):
            return "Request timed out after \(ms)ms"
        case .tlsError(let details):
            return "TLS error: \(details)"
        case .webSocketError(let details):
            return "WebSocket error: \(details)"
        case .invalidResponse(let details):
            return "Invalid response: \(details)"
        case .jsonRpcError(let code, let message):
            return "JSON-RPC error \(code): \(message)"
        case .discoveryFailed(let details):
            return "Service discovery failed: \(details)"
        }
    }
}
