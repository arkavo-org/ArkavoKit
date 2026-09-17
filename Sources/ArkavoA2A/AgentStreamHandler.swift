import Foundation
import ArkavoSocial
import Combine

/// Handles streaming message deltas from chat sessions
@MainActor
public final class AgentStreamHandler: ObservableObject, AgentNotificationHandler {
    // MARK: - Published Properties

    /// Currently accumulated streaming text for the session
    @Published public private(set) var streamingText: String = ""

    /// Whether a stream is currently active
    @Published public private(set) var isStreaming: Bool = false

    /// Current message ID being streamed
    @Published public private(set) var currentMessageId: String?

    /// Last error encountered during streaming
    @Published public private(set) var lastError: String?

    // MARK: - Private Properties

    private let sessionId: String
    private let connection: AgentConnection
    private var lastSequence: Int = 0
    private var subscriptionId: String?

    // Accumulated tool calls
    private var toolCalls: [String: ToolCallAccumulator] = [:]

    // Auto-acknowledgment task
    private var ackTask: Task<Void, Never>?

    // MARK: - Initialization

    public init(sessionId: String, connection: AgentConnection) {
        self.sessionId = sessionId
        self.connection = connection
    }

    // MARK: - Subscription Management

    /// Subscribe to message deltas for this session
    public func subscribe() async throws {
        print("[AgentStreamHandler] Subscribing to chat stream for session: \(sessionId)")

        isStreaming = true
        streamingText = ""
        lastError = nil
        lastSequence = 0

        // Send chat_stream subscription request
        let params: [String: Any] = [
            "session_id": sessionId
        ]

        print("[AgentStreamHandler] Calling chat_stream with params: \(params)")

        let response = try await connection.call(
            method: "chat_stream",
            params: params
        )

        print("[AgentStreamHandler] Got subscription response: \(response)")

        guard case .success(_, let result) = response else {
            if case .error(_, let code, let message) = response {
                print("[AgentStreamHandler] ERROR: Subscription failed: \(code) - \(message)")
                throw AgentError.jsonRpcError(code: code, message: message)
            }
            print("[AgentStreamHandler] ERROR: Invalid subscription response")
            throw AgentError.invalidResponse("Failed to subscribe to chat stream")
        }

        // Extract subscription ID if present
        if let subDict = result.value as? [String: Any],
           let subId = subDict["subscription"] as? String {
            subscriptionId = subId
            print("[AgentStreamHandler] Subscribed with ID: \(subId)")
        } else {
            print("[AgentStreamHandler] WARNING: No subscription ID in response")
        }

        print("[AgentStreamHandler] Subscription complete, streaming active")
    }

    /// Unsubscribe from message deltas
    public func unsubscribe() async {
        isStreaming = false
        subscriptionId = nil

        // Cancel auto-acknowledgment task
        ackTask?.cancel()
        ackTask = nil
    }

    // MARK: - Notification Handling

    public func handleNotification(method: String, params: AnyCodable) async {
        guard method == "chat_stream" else {
            return
        }

        // Parse notification params
        guard let paramsDict = params.value as? [String: Any] else {
            return
        }

        // Check if this is for our session
        guard let resultDict = paramsDict["result"] as? [String: Any],
              let msgSessionId = resultDict["session_id"] as? String,
              msgSessionId == sessionId else {
            return
        }

        // Extract delta information
        guard let messageId = resultDict["message_id"] as? String,
              let sequence = resultDict["sequence"] as? Int,
              let deltaDict = resultDict["delta"] as? [String: Any],
              let deltaType = deltaDict["type"] as? String else {
            return
        }

        // Update current message ID if changed
        if currentMessageId != messageId {
            // New message started, reset accumulation
            currentMessageId = messageId
            streamingText = ""
            toolCalls.removeAll()
        }

        lastSequence = sequence

        // Process delta based on type
        switch deltaType {
        case "text":
            if let text = deltaDict["text"] as? String {
                streamingText += text
            }

        case "toolCall":
            handleToolCallDelta(deltaDict)

        case "streamEnd":
            handleStreamEnd(deltaDict)

        case "error":
            handleStreamError(deltaDict)

        default:
            print("[AgentStreamHandler] Unknown delta type: \(deltaType)")
        }
    }

    // MARK: - Delta Processing

    private func handleToolCallDelta(_ delta: [String: Any]) {
        guard let toolCallId = delta["tool_call_id"] as? String else {
            return
        }

        // Get or create accumulator for this tool call
        var accumulator = toolCalls[toolCallId] ?? ToolCallAccumulator()

        // Update with new data
        if let name = delta["name"] as? String {
            accumulator.name = name
        }

        if let argsFragment = delta["args_json_fragment"] as? String {
            accumulator.argsJson += argsFragment
        }

        if let done = delta["done"] as? Bool, done {
            accumulator.isDone = true
        }

        toolCalls[toolCallId] = accumulator

        // Optionally, append tool call representation to streaming text
        if accumulator.isDone, let name = accumulator.name {
            streamingText += "\n[Tool Call: \(name)]"
        }
    }

    private func handleStreamEnd(_ delta: [String: Any]) {
        print("[AgentStreamHandler] handleStreamEnd called, setting isStreaming = false")
        isStreaming = false

        // Cancel auto-acknowledgment task
        print("[AgentStreamHandler] Cancelling auto-ack task")
        ackTask?.cancel()
        ackTask = nil

        // Extract end reason if present
        if let reason = delta["reason"] as? String {
            print("[AgentStreamHandler] Stream ended: \(reason)")
        } else {
            print("[AgentStreamHandler] Stream ended (no reason provided)")
        }
    }

    private func handleStreamError(_ delta: [String: Any]) {
        if let code = delta["code"] as? Int,
           let message = delta["message"] as? String {
            lastError = "Stream error \(code): \(message)"
            isStreaming = false

            // Cancel auto-acknowledgment task
            ackTask?.cancel()
            ackTask = nil
        }
    }

    // MARK: - Back-pressure Management

    /// Acknowledge received deltas up to the given sequence
    public func acknowledgeUpTo(sequence: Int) async throws {
        let params: [String: Any] = [
            "session_id": sessionId,
            "last_seq": sequence
        ]

        // Mark as nonisolated since params is created locally
        nonisolated(unsafe) let paramsForCall = params

        // Send chat_metrics_ack (don't wait for response, but don't spawn new task)
        _ = try? await connection.call(
            method: "chat_metrics_ack",
            params: paramsForCall
        )
    }

    /// Automatically acknowledge received messages periodically
    public func startAutoAcknowledgment(interval: TimeInterval = 0.5) {
        // Only start if streaming is active
        guard isStreaming else {
            print("[AgentStreamHandler] WARNING: Not starting auto-ack, streaming is not active")
            return
        }

        // Cancel any existing acknowledgment task to prevent duplicates
        ackTask?.cancel()

        print("[AgentStreamHandler] Starting auto-acknowledgment loop")

        // Start new acknowledgment task
        ackTask = Task {
            var ackCount = 0
            while isStreaming && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

                // Check again after sleep in case stream ended
                guard isStreaming && !Task.isCancelled else {
                    print("[AgentStreamHandler] Auto-ack loop stopped (sent \(ackCount) acks)")
                    break
                }

                if lastSequence > 0 {
                    ackCount += 1
                    try? await acknowledgeUpTo(sequence: lastSequence)
                }
            }
            print("[AgentStreamHandler] Auto-ack task completed after \(ackCount) acknowledgments")
        }
    }

    // MARK: - Public Accessors

    /// Get the accumulated text for the current message
    public func getAccumulatedText() -> String {
        streamingText
    }

    /// Get completed tool calls
    public func getToolCalls() -> [ToolCallInfo] {
        toolCalls
            .filter { $0.value.isDone }
            .map { (id, acc) in
                ToolCallInfo(
                    id: id,
                    name: acc.name ?? "unknown",
                    argsJson: acc.argsJson
                )
            }
    }
}

// MARK: - Supporting Types

private struct ToolCallAccumulator {
    var name: String?
    var argsJson: String = ""
    var isDone: Bool = false
}

/// Information about a completed tool call
public struct ToolCallInfo: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let argsJson: String
}
