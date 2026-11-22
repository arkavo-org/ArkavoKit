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

    // Auto-acknowledgment task (cancelled in deinit)
    nonisolated(unsafe) private var ackTask: Task<Void, Never>?

    // MARK: - Initialization

    public init(sessionId: String, connection: AgentConnection) {
        self.sessionId = sessionId
        self.connection = connection
    }

    deinit {
        ackTask?.cancel()
    }

    // MARK: - Subscription Management

    /// Subscribe to message deltas for this session
    public func subscribe() async throws {
        print("[AgentStreamHandler] Subscribing to chat stream for session: \(sessionId)")

        isStreaming = false
        streamingText = ""
        lastError = nil
        lastSequence = 0

        // Register as notification handler before subscribing so early deltas are delivered
        await connection.setNotificationHandler(self)

        print("[AgentStreamHandler] Calling chat_stream with positional params: [\(sessionId)]")

        let response: AgentResponse
        do {
            response = try await connection.call(
                method: "chat_stream",
                arrayParams: [sessionId]
            )
        } catch {
            await connection.setNotificationHandler(nil)
            isStreaming = false
            throw error
        }

        print("[AgentStreamHandler] Got subscription response: \(response)")

        guard case .success(_, let result) = response else {
            await connection.setNotificationHandler(nil)
            isStreaming = false
            if case .error(_, let code, let message) = response {
                print("[AgentStreamHandler] ERROR: Subscription failed: \(code) - \(message)")
                throw AgentError.jsonRpcError(code: code, message: message)
            }
            print("[AgentStreamHandler] ERROR: Invalid subscription response")
            throw AgentError.invalidResponse("Failed to subscribe to chat stream")
        }

        // Extract subscription ID from string, int, or dictionary result
        if let subId = result.value as? String {
            subscriptionId = subId
            print("[AgentStreamHandler] Subscribed with ID: \(subId)")
        } else if let subInt = result.value as? Int {
            let subId = String(subInt)
            subscriptionId = subId
            print("[AgentStreamHandler] Subscribed with ID: \(subId)")
        } else if let subDict = result.value as? [String: Any] {
            if let subId = subDict["subscription"] as? String {
                subscriptionId = subId
                print("[AgentStreamHandler] Subscribed with ID: \(subId)")
            } else if let subInt = subDict["subscription"] as? Int {
                let subId = String(subInt)
                subscriptionId = subId
                print("[AgentStreamHandler] Subscribed with ID: \(subId)")
            } else if let subId = subDict["subscription_id"] as? String {
                subscriptionId = subId
                print("[AgentStreamHandler] Subscribed with ID: \(subId)")
            } else if let subInt = subDict["subscription_id"] as? Int {
                let subId = String(subInt)
                subscriptionId = subId
                print("[AgentStreamHandler] Subscribed with ID: \(subId)")
            } else {
                print("[AgentStreamHandler] WARNING: No subscription ID in response")
            }
        } else {
            print("[AgentStreamHandler] WARNING: No subscription ID in response")
        }

        isStreaming = true
        print("[AgentStreamHandler] Subscription complete, streaming active")
    }

    /// Unsubscribe from message deltas
    public func unsubscribe() async {
        let currentSubId = subscriptionId
        isStreaming = false
        subscriptionId = nil

        // Cancel auto-acknowledgment task
        ackTask?.cancel()
        ackTask = nil

        if let currentSubId {
            _ = try? await connection.call(
                method: "chat_stream_unsubscribe",
                arrayParams: [currentSubId]
            )
        }

        await connection.setNotificationHandler(nil)
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

        // Start new acknowledgment task (capture weak self to avoid retain cycle)
        ackTask = Task { [weak self] in
            var ackCount = 0
            while !Task.isCancelled {
                guard self?.isStreaming == true else { break }

                try? await Task.sleep(nanoseconds: UInt64(max(0.01, interval) * 1_000_000_000))

                // Check again after sleep in case stream ended or handler was deallocated
                guard let self, self.isStreaming, !Task.isCancelled else {
                    print("[AgentStreamHandler] Auto-ack loop stopped (sent \(ackCount) acks)")
                    break
                }

                if self.lastSequence > 0 {
                    ackCount += 1
                    try? await self.acknowledgeUpTo(sequence: self.lastSequence)
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
