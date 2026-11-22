import ArkavoSocial
import Foundation
import Network
import OSLog
#if os(iOS)
import UIKit
#endif
#if canImport(FoundationModels)
    import FoundationModels
#endif
#if canImport(ImagePlayground)
    import ImagePlayground
#endif

/// LocalAIAgent: A participant agent that exposes on-device capabilities via A2A protocol
/// - Publishes itself as an A2A service via mDNS
/// - Handles sensor requests with policy enforcement
/// - Executes local tool calls (Foundation Models, Writing Tools, Image Playground)
/// - Routes to Orchestrator for task planning
@MainActor
public final class LocalAIAgent: NSObject, ObservableObject {
    public static let shared = LocalAIAgent()

    @Published public private(set) var isPublishing = false
    @Published public private(set) var lastError: String?

    private var listener: NWListener?
    private let sensorBridge: SensorBridge
    private let appleIntelligenceClient: AppleIntelligenceClient
    private let writingTools: WritingToolsIntegration
    private let imagePlayground: ImagePlaygroundIntegration
    private var connections: [UUID: NWConnection] = [:]
    private var partialMessages: [UUID: Data] = [:]

    /// Maximum accumulated fragmented WebSocket message size (16 MiB)
    private static let maxWebSocketMessageBytes = 16 * 1024 * 1024

    // Unique agent ID based on device
    private let agentId: String
    private let agentName: String
    private let agentPurpose = "On-device intelligence and sensor access"

    // In-process chat sessions (for direct calls, not WebSocket)
    private var inProcessSessions: [String: InProcessChatSession] = [:]

    /// Key for persisted agent ID in UserDefaults
    private static let agentIdKey = "com.arkavo.localai.agentId"

    private override init() {
        // Generate unique agent ID - use persisted random ID instead of device identifiers
        let deviceId: String
        if let existingId = UserDefaults.standard.string(forKey: Self.agentIdKey) {
            deviceId = existingId
        } else {
            // Generate and persist a new random ID (8 chars)
            let newId = String(UUID().uuidString.prefix(8))
            UserDefaults.standard.set(newId, forKey: Self.agentIdKey)
            deviceId = newId
        }

        #if os(iOS)
        let deviceName = UIDevice.current.name
        #elseif os(macOS)
        let deviceName = Host.current().localizedName ?? "Mac"
        #else
        let deviceName = "Device"
        #endif

        self.agentId = "device_agent_\(deviceId)"
        self.agentName = "Device Agent (\(deviceName))"

        sensorBridge = SensorBridge()
        appleIntelligenceClient = AppleIntelligenceClient()
        writingTools = WritingToolsIntegration()
        imagePlayground = ImagePlaygroundIntegration()
        super.init()
    }

    // MARK: - Public Properties

    /// Get the unique agent ID for this device
    public var id: String {
        agentId
    }

    /// Get the agent name
    public var name: String {
        agentName
    }

    // MARK: - Direct In-Process API (No WebSocket)

    /// Open a direct chat session (in-process, no WebSocket)
    public func openDirectChatSession() -> String {
        let sessionId = UUID().uuidString
        let session = InProcessChatSession(
            id: sessionId,
            createdAt: Date(),
            messages: []
        )
        inProcessSessions[sessionId] = session
        print("[LocalAIAgent] Opened direct chat session: \(sessionId)")
        return sessionId
    }

    /// Send a message and get response (in-process, no WebSocket)
    public func sendDirectMessage(sessionId: String, content: String) async throws -> String {
        guard inProcessSessions[sessionId] != nil else {
            throw LocalAIAgentError.sessionNotFound
        }

        print("[LocalAIAgent] Processing direct message in session: \(sessionId)")

        // Mutate live session directly before awaiting to prevent actor-reentrancy message loss
        let userMessage = ChatMessage(role: "user", content: content)
        inProcessSessions[sessionId]?.messages.append(userMessage)

        guard let sessionSnapshot = inProcessSessions[sessionId] else {
            throw LocalAIAgentError.sessionNotFound
        }

        // Generate response using Foundation Models
        let response = try await generateResponse(for: content, session: sessionSnapshot)

        print("[LocalAIAgent] Generated response: \(response)")

        // Re-verify session still exists after suspension so closed sessions are never resurrected
        guard inProcessSessions[sessionId] != nil else {
            throw LocalAIAgentError.sessionNotFound
        }

        // Append assistant message directly to live session
        let assistantMessage = ChatMessage(role: "assistant", content: response)
        inProcessSessions[sessionId]?.messages.append(assistantMessage)

        print("[LocalAIAgent] Returning response of length: \(response.count)")
        return response
    }

    /// Close a direct chat session
    public func closeDirectChatSession(sessionId: String) {
        inProcessSessions.removeValue(forKey: sessionId)
        print("[LocalAIAgent] Closed direct chat session: \(sessionId)")
    }

    /// Get chat history for a session
    public func getChatHistory(sessionId: String) -> [ChatMessage] {
        inProcessSessions[sessionId]?.messages ?? []
    }

    /// Execute a tool directly (sentiment analysis, summarization, etc.)
    public func executeTool(name: String, args: [String: Any]) async throws -> [String: Any] {
        print("[LocalAIAgent] Executing tool: \(name)")

        switch name {
        case "sentiment_analysis":
            return try await performSentimentAnalysis(args: args)
        case "summarize":
            return try await performSummarization(args: args)
        case "proofread":
            return try await performProofreading(args: args)
        default:
            // Delegate to existing tool implementations
            let toolCall = ToolCall(
                toolCallId: UUID().uuidString,
                name: name,
                args: AnyCodable(args),
                locality: .local
            )
            let result = try await executeLocalToolCall(toolCall)
            guard result.success else {
                throw LocalAIAgentError.toolExecutionFailed(result.error ?? "Tool '\(name)' failed")
            }
            return result.result?.value as? [String: Any] ?? [:]
        }
    }

    // MARK: - WebSocket Server (for cross-device A2A)

    /// Start publishing the LocalAIAgent as an A2A service.
    /// Defaults to loopback (`127.0.0.1`) to avoid exposing an unauthenticated LAN control service;
    /// pass `allowLAN: true` (ideally with an `authToken`) to advertise over LAN/mDNS.
    public func startPublishing(
        port: UInt16 = 0,
        allowLAN: Bool = false,
        authToken: String? = nil
    ) throws {
        guard !isPublishing else {
            print("[LocalAIAgent] Already publishing")
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = allowLAN

        let nwPort: NWEndpoint.Port = port == 0 ? .any : NWEndpoint.Port(integerLiteral: port)
        if !allowLAN {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: nwPort
            )
        }

        // Configure WebSocket options with client request handler
        // Without this handler, NWListener rejects URLSession WebSocket clients
        // with "client request doesn't match expected value" error
        let expectedToken = authToken
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.setClientRequestHandler(DispatchQueue.main) { subprotocols, headers in
            if let expectedToken, !expectedToken.isEmpty {
                let authHeader = headers.first {
                    $0.name.caseInsensitiveCompare("Authorization") == .orderedSame
                }?.value
                guard authHeader == "Bearer \(expectedToken)" else {
                    return NWProtocolWebSocket.Response(
                        status: .reject,
                        subprotocol: nil,
                        additionalHeaders: nil
                    )
                }
            }

            // Return the first requested subprotocol if any, otherwise accept with no subprotocol
            let selectedSubprotocol = subprotocols.first
            return NWProtocolWebSocket.Response(
                status: .accept,
                subprotocol: selectedSubprotocol,
                additionalHeaders: nil
            )
        }
        params.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        if allowLAN {
            listener = try NWListener(using: params, on: nwPort)
            listener?.service = NWListener.Service(
                name: agentName,
                type: "_a2a._tcp",
                txtRecord: buildTxtRecord()
            )
        } else {
            listener = try NWListener(using: params)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleListenerState(state)
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.handleNewConnection(connection)
            }
        }

        listener?.start(queue: .main)
        isPublishing = true

        print("[LocalAIAgent] Started publishing on port \(port) (allowLAN: \(allowLAN))")
    }

    /// Stop publishing the A2A service
    public func stopPublishing() {
        listener?.cancel()
        listener = nil

        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        partialMessages.removeAll()

        isPublishing = false
        print("[LocalAIAgent] Stopped publishing")
    }

    private func buildTxtRecord() -> NWTXTRecord {
        var record = NWTXTRecord()

        record["agent_id"] = agentId
        record["name"] = agentName
        record["purpose"] = agentPurpose
        record["model"] = "on-device"
        record["capabilities"] = "sensors,foundation_models,writing_tools,image_playground"

        return record
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port {
                print("[LocalAIAgent] Listener ready on port \(port)")
            }
        case let .failed(error):
            print("[LocalAIAgent] Listener failed: \(error)")
            lastError = error.localizedDescription
            isPublishing = false
        case .cancelled:
            print("[LocalAIAgent] Listener cancelled")
            isPublishing = false
        default:
            break
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let connectionId = UUID()
        connections[connectionId] = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleConnectionState(connectionId, state: state)
            }
        }

        connection.start(queue: .main)

        receiveMessage(from: connection, connectionId: connectionId)

        print("[LocalAIAgent] New connection: \(connectionId)")
    }

    private func handleConnectionState(_ connectionId: UUID, state: NWConnection.State) {
        switch state {
        case .ready:
            print("[LocalAIAgent] Connection ready: \(connectionId)")
        case let .failed(error):
            print("[LocalAIAgent] Connection failed: \(connectionId), error: \(error)")
            connections.removeValue(forKey: connectionId)
            partialMessages.removeValue(forKey: connectionId)
        case .cancelled:
            print("[LocalAIAgent] Connection cancelled: \(connectionId)")
            connections.removeValue(forKey: connectionId)
            partialMessages.removeValue(forKey: connectionId)
        default:
            break
        }
    }

    private func cleanupConnection(_ connectionId: UUID, connection: NWConnection) {
        connections.removeValue(forKey: connectionId)
        partialMessages.removeValue(forKey: connectionId)
        connection.cancel()
    }

    private func receiveMessage(from connection: NWConnection, connectionId: UUID) {
        connection.receiveMessage { [weak self] completeContent, contentContext, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    print("[LocalAIAgent] Receive error: \(error)")
                    self.cleanupConnection(connectionId, connection: connection)
                    return
                }

                // Close cleanly on WebSocket close opcode
                if let metadata = contentContext?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
                   metadata.opcode == .close {
                    print("[LocalAIAgent] WebSocket close frame received: \(connectionId)")
                    self.cleanupConnection(connectionId, connection: connection)
                    return
                }

                // Close cleanly on EOF
                if contentContext?.isFinal == true && (completeContent == nil || completeContent?.isEmpty == true) {
                    print("[LocalAIAgent] Connection EOF: \(connectionId)")
                    self.cleanupConnection(connectionId, connection: connection)
                    return
                }

                if let data = completeContent, !data.isEmpty {
                    if isComplete {
                        let fullMessage: Data
                        if var buffered = self.partialMessages.removeValue(forKey: connectionId) {
                            guard buffered.count + data.count <= Self.maxWebSocketMessageBytes else {
                                print("[LocalAIAgent] Message exceeded size limit on connection: \(connectionId)")
                                self.cleanupConnection(connectionId, connection: connection)
                                return
                            }
                            buffered.append(data)
                            fullMessage = buffered
                        } else {
                            fullMessage = data
                        }
                        await self.handleMessage(fullMessage, from: connection, connectionId: connectionId)
                    } else {
                        var buffer = self.partialMessages[connectionId] ?? Data()
                        guard buffer.count + data.count <= Self.maxWebSocketMessageBytes else {
                            print("[LocalAIAgent] Fragmented message exceeded size limit on connection: \(connectionId)")
                            self.cleanupConnection(connectionId, connection: connection)
                            return
                        }
                        buffer.append(data)
                        self.partialMessages[connectionId] = buffer
                    }
                } else if isComplete,
                          let buffered = self.partialMessages.removeValue(forKey: connectionId),
                          !buffered.isEmpty {
                    await self.handleMessage(buffered, from: connection, connectionId: connectionId)
                }

                // Always schedule next read while connection remains open
                if contentContext?.isFinal == true {
                    self.cleanupConnection(connectionId, connection: connection)
                } else if self.connections[connectionId] != nil {
                    self.receiveMessage(from: connection, connectionId: connectionId)
                }
            }
        }
    }

    private func handleMessage(_ data: Data, from connection: NWConnection, connectionId: UUID) async {
        var requestId: String?
        do {
            guard let jsonString = String(data: data, encoding: .utf8) else {
                throw LocalAIAgentError.invalidMessageEncoding
            }

            let requestData = Data(jsonString.utf8)
            if let rawJSON = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any] {
                if let idString = rawJSON["id"] as? String {
                    requestId = idString
                } else if let idInt = rawJSON["id"] as? Int {
                    requestId = String(idInt)
                }
            }

            let request = try JSONDecoder().decode(AgentRequest.self, from: requestData)
            requestId = request.id

            print("[LocalAIAgent] Received request: \(request.method) (connection: \(connectionId))")

            let response = try await processRequest(request)

            try await sendResponse(response, to: connection)
        } catch {
            print("[LocalAIAgent] Error handling message: \(error)")

            let errorResponse = AgentResponse.error(
                id: requestId ?? UUID().uuidString,
                code: -32603,
                message: error.localizedDescription
            )

            try? await sendResponse(errorResponse, to: connection)
        }
    }

    func processRequest(_ request: AgentRequest) async throws -> AgentResponse {
        switch request.method {
        case "sensor_request":
            return try await handleSensorRequest(request)
        case "tool_call":
            return try await handleToolCall(request)
        case "task_offer":
            return try await handleTaskOffer(request)
        case "chat_open":
            return try await handleChatOpen(request)
        default:
            throw LocalAIAgentError.unknownMethod(request.method)
        }
    }

    private func handleSensorRequest(_ request: AgentRequest) async throws -> AgentResponse {
        let sensorRequest = try decodeParams(SensorRequest.self, from: request.params)

        let sensorResponse = try await sensorBridge.requestSensorData(sensorRequest)
        let encodedResult = try encodeToAnyCodable(sensorResponse)

        return AgentResponse.success(
            id: request.id,
            result: encodedResult
        )
    }

    private func handleToolCall(_ request: AgentRequest) async throws -> AgentResponse {
        let toolCall = try decodeParams(ToolCall.self, from: request.params)

        guard toolCall.locality == .local else {
            throw LocalAIAgentError.remoteToolCallNotSupported
        }

        let result = try await executeLocalToolCall(toolCall)
        let encodedResult = try encodeToAnyCodable(result)

        return AgentResponse.success(
            id: request.id,
            result: encodedResult
        )
    }

    private func executeLocalToolCall(_ toolCall: ToolCall) async throws -> ToolCallResult {
        // Route to appropriate local capability based on tool name
        if toolCall.name.starts(with: "foundation_models_") {
            return try await appleIntelligenceClient.executeToolCall(toolCall)
        } else if toolCall.name.starts(with: "writing_tools_") {
            return try await writingTools.executeToolCall(toolCall)
        } else if toolCall.name.starts(with: "image_playground_") {
            return try await imagePlayground.executeToolCall(toolCall)
        } else {
            throw LocalAIAgentError.toolNotImplemented(toolCall.name)
        }
    }

    private func handleTaskOffer(_ request: AgentRequest) async throws -> AgentResponse {
        let taskOffer = try decodeParams(TaskOffer.self, from: request.params)

        print("[LocalAIAgent] Received task offer: \(taskOffer.intent)")

        throw LocalAIAgentError.orchestratorRequired
    }

    private func handleChatOpen(_ request: AgentRequest) async throws -> AgentResponse {
        print("[LocalAIAgent] Opening chat session")

        // Create a simple chat session
        let sessionId = UUID().uuidString
        let capabilities = ChatCapabilities(
            supportedMessageTypes: ["text"],
            maxMessageLength: 10000,
            supportsStreaming: false
        )
        let session = ChatSession(
            id: sessionId,
            capabilities: capabilities,
            createdAt: Date()
        )
        let encodedSession = try encodeToAnyCodable(session)

        return AgentResponse.success(
            id: request.id,
            result: encodedSession
        )
    }

    /// Encode any `Encodable` value into a JSON-backed `AnyCodable` so structs never serialize as `null`
    func encodeToAnyCodable<T: Encodable>(_ value: T) throws -> AnyCodable {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(AnyCodable.self, from: data)
    }

    private func sendResponse(_ response: AgentResponse, to connection: NWConnection) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(response)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "textMessage",
            metadata: [metadata]
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private func decodeParams<T: Decodable>(_ type: T.Type, from params: AnyCodable) throws -> T {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(params)
        return try decoder.decode(type, from: data)
    }

    /// Get current device capabilities
    public func getDeviceCapabilities() -> DeviceCapabilities {
        DeviceCapabilities(
            aiCapabilities: [
                .foundationModels,
                .writingTools,
                .imagePlayground,
                .speechRecognition,
                .textToSpeech,
            ],
            sensors: [
                .location,
                .camera,
                .microphone,
                .motion,
                .nearbyDevices,
                .compass,
            ],
            platform: getCurrentPlatform(),
            osVersion: getOSVersion()
        )
    }

    private func getCurrentPlatform() -> DevicePlatform {
        #if os(iOS)
            return .ios
        #elseif os(macOS)
            return .macos
        #elseif os(tvOS)
            return .tvos
        #elseif os(watchOS)
            return .watchos
        #else
            return .ios
        #endif
    }

    private func getOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    // MARK: - Tool Implementations

    /// Generate a response for the user's message
    private func generateResponse(for message: String, session: InProcessChatSession) async throws -> String {
        print("[LocalAIAgent] generateResponse called with message: '\(message)'")

        // Try to use Foundation Models if available
        if appleIntelligenceClient.isAvailable {
            print("[LocalAIAgent] Foundation Models available, attempting to use")
            let toolCall = ToolCall(
                toolCallId: UUID().uuidString,
                name: "foundation_models_generate",
                args: AnyCodable([
                    "prompt": message,
                    "max_tokens": 500,
                    "temperature": 0.7
                ]),
                locality: .local
            )
            let result = try await appleIntelligenceClient.executeToolCall(toolCall)
            if result.success, let text = result.result?.value as? [String: Any], let response = text["text"] as? String {
                print("[LocalAIAgent] Foundation Models returned: \(response)")
                return response
            }
            print("[LocalAIAgent] Foundation Models failed or returned no text, using fallback")
        } else {
            print("[LocalAIAgent] Foundation Models not available, using fallback")
        }

        // Fallback: Simple echo with context awareness
        let fallbackResponse = generateFallbackResponse(for: message, session: session)
        print("[LocalAIAgent] Fallback response: \(fallbackResponse)")
        return fallbackResponse
    }

    /// Fallback response when Foundation Models not available
    private func generateFallbackResponse(for message: String, session: InProcessChatSession) -> String {
        let lowerMessage = message.lowercased()

        // Simple intent detection
        if lowerMessage.contains("sentiment") || lowerMessage.contains("feeling") || lowerMessage.contains("emotion") {
            return "I can help analyze sentiment! Use the sentiment_analysis tool with text to analyze."
        } else if lowerMessage.contains("summarize") || lowerMessage.contains("summary") {
            return "I can summarize text for you. Use the summarize tool with the text you want summarized."
        } else if lowerMessage.contains("sensor") || lowerMessage.contains("location") {
            return "I have access to device sensors including location, motion, and compass. What would you like to know?"
        } else if lowerMessage.contains("hello") || lowerMessage.contains("hi") {
            return "Hello! I'm your LocalAI Agent running on-device. I can help with sentiment analysis, text summarization, sensor access, and more. Foundation Models will be available when iOS 26 APIs are integrated."
        } else {
            return "I received your message: '\(message)'. Foundation Models integration is pending. For now, I can help with sentiment analysis, summarization, and sensor access. What would you like to try?"
        }
    }

    /// Perform sentiment analysis on text
    private func performSentimentAnalysis(args: [String: Any]) async throws -> [String: Any] {
        guard let text = args["text"] as? String else {
            throw LocalAIAgentError.invalidArguments("Missing 'text' parameter")
        }

        print("[LocalAIAgent] Performing sentiment analysis on: \(text.prefix(50))...")

        // Use NL sentiment analysis if available on iOS
        #if os(iOS) || os(macOS)
        if #available(iOS 16.0, macOS 13.0, *) {
            return try await performNLSentimentAnalysis(text: text)
        }
        #endif

        // Fallback: Simple keyword-based sentiment
        return performSimpleSentiment(text: text)
    }

    #if os(iOS) || os(macOS)
    @available(iOS 16.0, macOS 13.0, *)
    private func performNLSentimentAnalysis(text: String) async throws -> [String: Any] {
        // TODO: Implement with NaturalLanguage framework
        // For now, use simple fallback
        return performSimpleSentiment(text: text)
    }
    #endif

    private func performSimpleSentiment(text: String) -> [String: Any] {
        let positiveWords = ["good", "great", "excellent", "amazing", "wonderful", "fantastic", "love", "happy", "joy"]
        let negativeWords = ["bad", "terrible", "awful", "horrible", "hate", "sad", "angry", "disappointed"]

        let lowerText = text.lowercased()
        var positiveCount = 0
        var negativeCount = 0

        for word in positiveWords {
            if lowerText.contains(word) {
                positiveCount += 1
            }
        }

        for word in negativeWords {
            if lowerText.contains(word) {
                negativeCount += 1
            }
        }

        let sentiment: String
        let score: Double

        if positiveCount > negativeCount {
            sentiment = "positive"
            score = min(1.0, Double(positiveCount) / Double(positiveCount + negativeCount + 1))
        } else if negativeCount > positiveCount {
            sentiment = "negative"
            score = -min(1.0, Double(negativeCount) / Double(positiveCount + negativeCount + 1))
        } else {
            sentiment = "neutral"
            score = 0.0
        }

        return [
            "sentiment": sentiment,
            "score": score,
            "confidence": abs(score),
            "positive_indicators": positiveCount,
            "negative_indicators": negativeCount
        ]
    }

    /// Perform text summarization
    private func performSummarization(args: [String: Any]) async throws -> [String: Any] {
        guard let text = args["text"] as? String else {
            throw LocalAIAgentError.invalidArguments("Missing 'text' parameter")
        }

        let length = args["length"] as? String ?? "medium"

        // Use Writing Tools if available; fall back gracefully when unavailable
        if writingTools.isAvailable {
            let toolCall = ToolCall(
                toolCallId: UUID().uuidString,
                name: "writing_tools_summarize",
                args: AnyCodable(["text": text, "length": length]),
                locality: .local
            )

            do {
                let result = try await writingTools.executeToolCall(toolCall)
                if result.success, let summary = result.result?.value as? [String: Any] {
                    return summary
                }
            } catch WritingToolsError.notAvailable {
                // Fall through to sentence extraction fallback
            }
        }

        // Fallback: Simple sentence extraction
        let sentences = text.components(separatedBy: ". ")
        let maxSentences = length == "short" ? 2 : (length == "long" ? 5 : 3)
        let summaryText = sentences.prefix(min(maxSentences, sentences.count)).joined(separator: ". ")

        return [
            "summary": summaryText + (sentences.count > maxSentences ? "..." : ""),
            "original_length": text.count,
            "summary_length": summaryText.count
        ]
    }

    /// Perform proofreading
    private func performProofreading(args: [String: Any]) async throws -> [String: Any] {
        guard let text = args["text"] as? String else {
            throw LocalAIAgentError.invalidArguments("Missing 'text' parameter")
        }

        // Use Writing Tools if available; fall back gracefully when unavailable
        if writingTools.isAvailable {
            let toolCall = ToolCall(
                toolCallId: UUID().uuidString,
                name: "writing_tools_proofread",
                args: AnyCodable(["text": text]),
                locality: .local
            )

            do {
                let result = try await writingTools.executeToolCall(toolCall)
                if result.success, var proofread = result.result?.value as? [String: Any] {
                    // Ensure consistent key schema ("corrected_text" and "text")
                    if proofread["corrected_text"] == nil, let textValue = proofread["text"] as? String {
                        proofread["corrected_text"] = textValue
                    }
                    if proofread["text"] == nil, let correctedValue = proofread["corrected_text"] as? String {
                        proofread["text"] = correctedValue
                    }
                    return proofread
                }
            } catch WritingToolsError.notAvailable {
                // Fall through to passthrough fallback
            }
        }

        return ["corrected_text": text, "text": text, "corrections": []]
    }
}

// MARK: - Supporting Types

/// In-process chat session (no WebSocket)
struct InProcessChatSession {
    let id: String
    let createdAt: Date
    var messages: [ChatMessage]
}

/// Chat message
public struct ChatMessage: Codable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public enum LocalAIAgentError: Error, LocalizedError {
    case invalidMessageEncoding
    case unknownMethod(String)
    case remoteToolCallNotSupported
    case toolNotImplemented(String)
    case toolExecutionFailed(String)
    case orchestratorRequired
    case notImplemented
    case sessionNotFound
    case invalidArguments(String)

    public var errorDescription: String? {
        switch self {
        case .invalidMessageEncoding:
            return "Invalid message encoding"
        case let .unknownMethod(method):
            return "Unknown method: \(method)"
        case .remoteToolCallNotSupported:
            return "Remote tool calls must be sent to Orchestrator"
        case let .toolNotImplemented(name):
            return "Tool not yet implemented: \(name)"
        case let .toolExecutionFailed(detail):
            return "Tool execution failed: \(detail)"
        case .orchestratorRequired:
            return "Task offers must be sent to Orchestrator for planning"
        case .notImplemented:
            return "Feature not yet implemented"
        case .sessionNotFound:
            return "Chat session not found"
        case let .invalidArguments(detail):
            return "Invalid arguments: \(detail)"
        }
    }
}
