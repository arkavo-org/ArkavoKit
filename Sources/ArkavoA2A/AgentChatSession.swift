import Foundation
import ArkavoSocial
import Combine

/// Represents a chat session with an A2A agent
public struct ChatSession: Codable, Identifiable, Sendable {
    public let id: String
    public let capabilities: ChatCapabilities?
    public let createdAt: Date

    public init(id: String, capabilities: ChatCapabilities? = nil, createdAt: Date) {
        self.id = id
        self.capabilities = capabilities
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id = "session_id"
        case capabilities
        case createdAt = "created_at"
    }
}

/// Chat capabilities for a session
public struct ChatCapabilities: Codable, Sendable {
    public let supportedMessageTypes: [String]?
    public let maxMessageLength: Int?
    public let supportsStreaming: Bool?

    public init(supportedMessageTypes: [String]? = nil, maxMessageLength: Int? = nil, supportsStreaming: Bool? = nil) {
        self.supportedMessageTypes = supportedMessageTypes
        self.maxMessageLength = maxMessageLength
        self.supportsStreaming = supportsStreaming
    }

    enum CodingKeys: String, CodingKey {
        case supportedMessageTypes = "supported_message_types"
        case maxMessageLength = "max_message_length"
        case supportsStreaming = "supports_streaming"
    }
}

/// Request to open a new chat session
public struct ChatOpenRequest: Codable, Sendable {
    public let token: String?
    public let context: [String: AnyCodable]?
    public let metadata: [String: AnyCodable]?

    public init(token: String? = nil, context: [String: AnyCodable]? = nil, metadata: [String: AnyCodable]? = nil) {
        self.token = token
        self.context = context
        self.metadata = metadata
    }
}

/// User message to send in a chat session
public struct UserMessage: Codable, Sendable {
    public let content: String
    public let attachments: [String]?
    public let metadata: [String: AnyCodable]?

    public init(content: String, attachments: [String]? = nil, metadata: [String: AnyCodable]? = nil) {
        self.content = content
        self.attachments = attachments
        self.metadata = metadata
    }
}

/// Message delta from the agent
public struct MessageDelta: Codable, Sendable {
    public let sessionId: String
    public let messageId: String
    public let sequence: Int
    public let delta: MessageDeltaContent
    public let timestamp: Date

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case messageId = "message_id"
        case sequence
        case delta
        case timestamp
    }
}

/// Content of a message delta
public enum MessageDeltaContent: Codable, Sendable {
    case text(text: String)
    case toolCall(toolCallId: String, name: String?, argsFragment: String, done: Bool)
    case streamEnd
    case error(code: Int, message: String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case toolCallId = "tool_call_id"
        case name
        case argsFragment = "args_json_fragment"
        case done
        case code
        case message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text: text)

        case "toolCall":
            let toolCallId = try container.decode(String.self, forKey: .toolCallId)
            let name = try? container.decode(String.self, forKey: .name)
            let argsFragment = try container.decode(String.self, forKey: .argsFragment)
            let done = try container.decode(Bool.self, forKey: .done)
            self = .toolCall(toolCallId: toolCallId, name: name, argsFragment: argsFragment, done: done)

        case "streamEnd":
            self = .streamEnd

        case "error":
            let code = try container.decode(Int.self, forKey: .code)
            let message = try container.decode(String.self, forKey: .message)
            self = .error(code: code, message: message)

        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown delta type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)

        case .toolCall(let toolCallId, let name, let argsFragment, let done):
            try container.encode("toolCall", forKey: .type)
            try container.encode(toolCallId, forKey: .toolCallId)
            if let name = name {
                try container.encode(name, forKey: .name)
            }
            try container.encode(argsFragment, forKey: .argsFragment)
            try container.encode(done, forKey: .done)

        case .streamEnd:
            try container.encode("streamEnd", forKey: .type)

        case .error(let code, let message):
            try container.encode("error", forKey: .type)
            try container.encode(code, forKey: .code)
            try container.encode(message, forKey: .message)
        }
    }
}

/// Manager for chat sessions with A2A agents
@MainActor
public final class AgentChatSessionManager: ObservableObject, AgentNotificationHandler, AgentConnectionDelegate {
    // MARK: - Published Properties

    @Published public private(set) var activeSessions: [String: ChatSession] = [:]
    @Published public private(set) var messageDeltas: [String: [MessageDelta]] = [:]
    @Published public private(set) var connectionRecoveryInProgress: Set<String> = []

    // MARK: - Private Properties

    private let agentManager: AgentManager
    private var sessionAgentMap: [String: String] = [:] // session_id -> agent_id
    private var agentSessionMap: [String: Set<String>] = [:] // agent_id -> session_ids
    private var deltaCallbacks: [String: (MessageDelta) -> Void] = [:] // session_id -> callback
    private var streamSubscriptionIds: [String: AnyCodable] = [:] // session_id -> subscription_id (Int or String)

    // MARK: - Initialization

    public init(agentManager: AgentManager = .shared) {
        self.agentManager = agentManager
    }

    // MARK: - Session Management

    /// Open a new chat session with an agent
    public func openSession(
        with agentId: String,
        token: String? = nil,
        context: [String: AnyCodable]? = nil
    ) async throws -> ChatSession {
        guard let connection = agentManager.getConnection(for: agentId) else {
            throw AgentError.notConnected
        }

        // Wait for connection to be fully ready with timeout
        // This handles any race conditions between connection establishment
        // and the transport reporting as connected
        let maxRetries = 10
        for attempt in 0..<maxRetries {
            if await connection.isConnected() {
                break
            }
            if attempt == maxRetries - 1 {
                throw AgentError.notConnected
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        let request = ChatOpenRequest(token: token, context: context)
        let requestParams = try encodeToAnyCodable(request)

        nonisolated(unsafe) let params: [String: Any] = ["request": requestParams]
        let response = try await connection.call(method: "chat_open", params: params)

        guard case .success(_, let result) = response else {
            if case .error(_, let code, let message) = response {
                throw AgentError.jsonRpcError(code: code, message: message)
            }
            throw AgentError.invalidResponse("Unexpected response format")
        }

        let session = try Self.decodeChatSession(from: result)

        activeSessions[session.id] = session
        sessionAgentMap[session.id] = agentId
        messageDeltas[session.id] = []

        // Track reverse mapping for session recovery
        if agentSessionMap[agentId] == nil {
            agentSessionMap[agentId] = []
        }
        agentSessionMap[agentId]?.insert(session.id)

        // Set up connection delegate for session recovery
        await connection.setConnectionDelegate(self)

        return session
    }

    /// Send a message in a chat session
    public func sendMessage(
        sessionId: String,
        content: String,
        attachments: [String]? = nil
    ) async throws {
        print("[AgentChatSessionManager] Sending message in session: \(sessionId)")

        guard activeSessions[sessionId] != nil else {
            print("[AgentChatSessionManager] ERROR: Session not found: \(sessionId)")
            throw AgentError.invalidResponse("Session not found")
        }

        guard let agentId = sessionAgentMap[sessionId],
              let connection = agentManager.getConnection(for: agentId) else {
            print("[AgentChatSessionManager] ERROR: Not connected to agent for session: \(sessionId)")
            throw AgentError.notConnected
        }

        let message = UserMessage(content: content, attachments: attachments)
        print("[AgentChatSessionManager] Created UserMessage with content length: \(content.count)")

        let messageParams = try encodeToAnyCodable(message)

        // Create params with session_id and nested message object
        let params: [String: Any] = [
            "session_id": sessionId,
            "message": messageParams
        ]

        print("[AgentChatSessionManager] Calling chat_send with params keys: \(params.keys.sorted())")

        // Mark as nonisolated(unsafe) since params is created locally and not shared
        nonisolated(unsafe) let paramsForCall = params
        let response = try await connection.call(
            method: "chat_send",
            params: paramsForCall
        )

        print("[AgentChatSessionManager] Received response: \(response)")

        guard case .success = response else {
            if case .error(_, let code, let message) = response {
                print("[AgentChatSessionManager] ERROR: RPC error \(code): \(message)")
                throw AgentError.jsonRpcError(code: code, message: message)
            }
            print("[AgentChatSessionManager] ERROR: Unexpected response format")
            throw AgentError.invalidResponse("Unexpected response format")
        }

        print("[AgentChatSessionManager] Message sent successfully")
    }

    /// Subscribe to the chat_stream to receive message deltas
    /// This MUST be called after openSession and BEFORE sendMessage
    public func subscribeToStream(
        sessionId: String,
        onDelta: @escaping (MessageDelta) -> Void
    ) async throws {
        print("[AgentChatSessionManager] Subscribing to chat_stream for session: \(sessionId)")

        guard activeSessions[sessionId] != nil else {
            print("[AgentChatSessionManager] ERROR: Session not found: \(sessionId)")
            throw AgentError.invalidResponse("Session not found")
        }

        guard let agentId = sessionAgentMap[sessionId],
              let connection = agentManager.getConnection(for: agentId) else {
            print("[AgentChatSessionManager] ERROR: Not connected to agent for session: \(sessionId)")
            throw AgentError.notConnected
        }

        // Store the callback for this session (restore/remove if subscription fails)
        let previousCallback = deltaCallbacks[sessionId]
        deltaCallbacks[sessionId] = onDelta

        // Set ourselves as the notification handler on the connection
        await connection.setNotificationHandler(self)

        // Subscribe to chat_stream via JSON-RPC subscription
        // Note: jsonrpsee uses positional (array) params for subscriptions
        let response: AgentResponse
        do {
            response = try await connection.call(
                method: "chat_stream",
                arrayParams: [sessionId]
            )
        } catch {
            if let previousCallback {
                deltaCallbacks[sessionId] = previousCallback
            } else {
                deltaCallbacks.removeValue(forKey: sessionId)
            }
            throw error
        }

        switch response {
        case .success(_, let result):
            if let subId = Self.extractSubscriptionId(from: result) {
                print("[AgentChatSessionManager] Successfully subscribed to chat_stream, subscription id: \(subId.value)")
                streamSubscriptionIds[sessionId] = subId
            } else {
                print("[AgentChatSessionManager] Subscribed to chat_stream (no subscription id returned)")
            }
        case .error(_, let code, let message):
            if let previousCallback {
                deltaCallbacks[sessionId] = previousCallback
            } else {
                deltaCallbacks.removeValue(forKey: sessionId)
            }
            print("[AgentChatSessionManager] ERROR: Failed to subscribe: \(code) - \(message)")
            throw AgentError.jsonRpcError(code: code, message: message)
        }
    }

    /// Handle notifications from the agent (implements AgentNotificationHandler)
    nonisolated public func handleNotification(method: String, params: AnyCodable) async {
        // Only handle chat_stream notifications
        guard method == "chat_stream" else {
            return
        }

        do {
            let delta = try Self.decodeMessageDelta(from: params)

            // Dispatch to the registered callback on MainActor only for active sessions
            await MainActor.run {
                guard activeSessions[delta.sessionId] != nil else {
                    return
                }
                if let callback = deltaCallbacks[delta.sessionId] {
                    callback(delta)
                }
                messageDeltas[delta.sessionId, default: []].append(delta)
            }
        } catch {
            print("[AgentChatSessionManager] Failed to decode chat_stream notification: \(error)")
        }
    }

    /// Close a chat session
    public func closeSession(sessionId: String) async {
        guard activeSessions.removeValue(forKey: sessionId) != nil else {
            return
        }

        // Remove callbacks and capture server subscription ID before clearing
        deltaCallbacks.removeValue(forKey: sessionId)
        let subscriptionId = streamSubscriptionIds.removeValue(forKey: sessionId)
        messageDeltas.removeValue(forKey: sessionId)

        guard let agentId = sessionAgentMap.removeValue(forKey: sessionId),
              let connection = agentManager.getConnection(for: agentId) else {
            return
        }

        // Remove from reverse mapping
        agentSessionMap[agentId]?.remove(sessionId)
        if agentSessionMap[agentId]?.isEmpty == true {
            agentSessionMap.removeValue(forKey: agentId)
        }

        // Unsubscribe from chat_stream using positional server subscription ID (preserving Int vs String type)
        if let subscriptionId {
            nonisolated(unsafe) let unsubscribeParams: [Any] = [subscriptionId.value]
            _ = try? await connection.call(
                method: "chat_stream_unsubscribe",
                arrayParams: unsubscribeParams
            )
        }

        _ = try? await connection.call(
            method: "chat_close",
            params: ["session_id": sessionId]
        )
    }

    // MARK: - AgentConnectionDelegate

    nonisolated public func connectionDidReconnect(agentId: String) async {
        await handleConnectionReconnect(agentId: agentId)
    }

    nonisolated public func connectionDidDisconnect(agentId: String, error: Error?) async {
        await handleConnectionDisconnect(agentId: agentId, error: error)
    }

    private func handleConnectionReconnect(agentId: String) async {
        print("[AgentChatSessionManager] Connection restored for agent: \(agentId)")

        guard let sessionIds = agentSessionMap[agentId], !sessionIds.isEmpty else {
            print("[AgentChatSessionManager] No active sessions to recover for agent: \(agentId)")
            return
        }

        connectionRecoveryInProgress.insert(agentId)

        // Re-subscribe to chat_stream for all active sessions
        for sessionId in sessionIds {
            guard activeSessions[sessionId] != nil else { continue }
            guard let callback = deltaCallbacks[sessionId] else { continue }

            print("[AgentChatSessionManager] Recovering session: \(sessionId)")

            do {
                // Re-subscribe to chat_stream
                try await resubscribeToStream(sessionId: sessionId, callback: callback)
                print("[AgentChatSessionManager] Session recovered: \(sessionId)")
            } catch {
                print("[AgentChatSessionManager] Failed to recover session \(sessionId): \(error)")
            }
        }

        connectionRecoveryInProgress.remove(agentId)
        print("[AgentChatSessionManager] Session recovery complete for agent: \(agentId)")
    }

    private func handleConnectionDisconnect(agentId: String, error: Error?) async {
        print("[AgentChatSessionManager] Connection lost for agent: \(agentId), error: \(error?.localizedDescription ?? "none")")

        // Clear subscription IDs since they're no longer valid
        if let sessionIds = agentSessionMap[agentId] {
            for sessionId in sessionIds {
                streamSubscriptionIds.removeValue(forKey: sessionId)
            }
        }
    }

    private func resubscribeToStream(sessionId: String, callback: @escaping (MessageDelta) -> Void) async throws {
        guard let agentId = sessionAgentMap[sessionId],
              let connection = agentManager.getConnection(for: agentId) else {
            throw AgentError.notConnected
        }

        // Store the callback
        deltaCallbacks[sessionId] = callback

        // Set ourselves as the notification handler
        await connection.setNotificationHandler(self)

        // Re-subscribe to chat_stream
        let response = try await connection.call(
            method: "chat_stream",
            arrayParams: [sessionId]
        )

        switch response {
        case .success(_, let result):
            if let subId = Self.extractSubscriptionId(from: result) {
                print("[AgentChatSessionManager] Re-subscribed to chat_stream: \(subId.value)")
                streamSubscriptionIds[sessionId] = subId
            }
        case .error(_, let code, let message):
            throw AgentError.jsonRpcError(code: code, message: message)
        }
    }

    // MARK: - Helpers

    nonisolated static func decodeChatSession(from result: AnyCodable) throws -> ChatSession {
        guard JSONSerialization.isValidJSONObject(result.value) else {
            throw AgentError.invalidResponse("Expected JSON object for chat session")
        }
        let sessionData = try JSONSerialization.data(withJSONObject: result.value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChatSession.self, from: sessionData)
    }

    nonisolated static func decodeMessageDelta(from params: AnyCodable) throws -> MessageDelta {
        // jsonrpsee subscription format: {"subscription": <id>, "result": <MessageDelta>}
        guard let paramsDict = params.value as? [String: Any],
              let resultValue = paramsDict["result"],
              JSONSerialization.isValidJSONObject(resultValue) else {
            throw AgentError.invalidResponse("Invalid subscription params format")
        }

        let data = try JSONSerialization.data(withJSONObject: resultValue)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MessageDelta.self, from: data)
    }

    nonisolated static func extractSubscriptionId(from result: AnyCodable) -> AnyCodable? {
        if let str = result.value as? String {
            return AnyCodable(str)
        }
        if let intVal = result.value as? Int {
            return AnyCodable(intVal)
        }
        if let dict = result.value as? [String: Any] {
            if let sub = dict["subscription"] as? String {
                return AnyCodable(sub)
            }
            if let subInt = dict["subscription"] as? Int {
                return AnyCodable(subInt)
            }
            if let sub = dict["subscription_id"] as? String {
                return AnyCodable(sub)
            }
            if let subInt = dict["subscription_id"] as? Int {
                return AnyCodable(subInt)
            }
        }
        return nil
    }

    private func encodeToAnyCodable<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder()
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }
}
