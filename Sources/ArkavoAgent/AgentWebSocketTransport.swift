import Foundation
import Combine

/// Delegate for connection state changes
public protocol AgentWebSocketTransportDelegate: AnyObject, Sendable {
    func transportDidConnect() async
    func transportDidDisconnect(error: Error?) async
    func transportWillReconnect(attempt: Int, delay: UInt64) async
}

/// WebSocket transport for A2A agent communication using JSON-RPC 2.0
@available(iOS 13.0, macOS 10.15, *)
public actor AgentWebSocketTransport {
    // MARK: - Properties

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var endpoint: AgentEndpoint?
    private var isConnected: Bool = false

    // Request/response correlation
    private var pendingRequests: [String: CheckedContinuation<AgentResponse, Error>] = [:]

    // Notification handler
    private weak var notificationHandler: (any AgentNotificationHandler)?

    // Connection state delegate
    private weak var delegate: (any AgentWebSocketTransportDelegate)?

    // Configuration
    private let timeoutMs: UInt64
    private let requireTLS: Bool

    // Heartbeat configuration
    private let heartbeatIntervalMs: UInt64
    private var heartbeatTask: Task<Void, Never>?
    private var lastPongTime: Date = Date()
    private let missedPongThreshold: Int

    // Reader task
    private var readerTask: Task<Void, Never>?

    // MARK: - Initialization

    public init(
        timeoutMs: UInt64 = 30000,
        requireTLS: Bool = false,
        heartbeatIntervalMs: UInt64 = 30000,
        missedPongThreshold: Int = 2
    ) {
        self.timeoutMs = timeoutMs
        self.requireTLS = requireTLS
        self.heartbeatIntervalMs = heartbeatIntervalMs
        self.missedPongThreshold = missedPongThreshold
    }

    /// Set the connection state delegate
    public func setDelegate(_ delegate: (any AgentWebSocketTransportDelegate)?) {
        self.delegate = delegate
    }

    // MARK: - Connection Management

    /// Connect to an agent endpoint
    public func connect(to endpoint: AgentEndpoint) async throws {
        guard endpoint.url.hasPrefix("ws://") || endpoint.url.hasPrefix("wss://") else {
            throw AgentError.invalidEndpoint("WebSocket URL must start with ws:// or wss://")
        }

        if requireTLS && endpoint.url.hasPrefix("ws://") {
            throw AgentError.tlsError("TLS is required but URL uses ws:// instead of wss://")
        }

        guard let url = URL(string: endpoint.url) else {
            throw AgentError.invalidEndpoint("Invalid URL: \(endpoint.url)")
        }

        // Create URL session configuration
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = TimeInterval(timeoutMs / 1000)
        configuration.timeoutIntervalForResource = TimeInterval(timeoutMs / 1000)

        let session = URLSession(configuration: configuration)
        self.session = session

        // Create WebSocket task
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        self.endpoint = endpoint

        // Resume the task to initiate connection
        task.resume()

        // Verify connection by sending a ping and waiting for pong
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error = error {
                        continuation.resume(throwing: AgentError.connectionFailed(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            task.cancel(with: .abnormalClosure, reason: nil)
            session.invalidateAndCancel()
            self.webSocketTask = nil
            self.session = nil
            self.endpoint = nil
            throw error
        }

        // Start receiving messages after connection is verified
        startReceiving(task: task)

        // Start heartbeat for keep-alive
        startHeartbeat(task: task)

        self.isConnected = true
        self.lastPongTime = Date()

        // Notify delegate
        if let delegate = delegate {
            await delegate.transportDidConnect()
        }
    }

    /// Close the connection
    public func close() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil

        readerTask?.cancel()
        readerTask = nil

        if let task = webSocketTask {
            task.cancel(with: .goingAway, reason: nil)
        }

        let wasConnected = isConnected

        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        endpoint = nil
        isConnected = false

        // Cancel all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: AgentError.connectionFailed("Connection closed"))
        }
        pendingRequests.removeAll()

        // Notify delegate if we were connected
        if wasConnected, let delegate = delegate {
            await delegate.transportDidDisconnect(error: nil)
        }
    }

    /// Get the stored endpoint (for reconnection)
    public func getEndpoint() -> AgentEndpoint? {
        endpoint
    }

    /// Check if connected
    public func getIsConnected() -> Bool {
        isConnected
    }

    /// Set the notification handler
    public func setNotificationHandler(_ handler: (any AgentNotificationHandler)?) {
        self.notificationHandler = handler
    }

    // MARK: - Request/Response

    /// Send a JSON-RPC request and await the response
    public func sendRequest(_ request: AgentRequest) async throws -> AgentResponse {
        guard isConnected, let task = webSocketTask else {
            print("[AgentWebSocketTransport] ERROR: Not connected")
            throw AgentError.notConnected
        }

        // Encode request to JSON
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            print("[AgentWebSocketTransport] ERROR: Failed to encode request as UTF-8")
            throw AgentError.webSocketError("Failed to encode request as UTF-8")
        }

        print("[AgentWebSocketTransport] Sending request: method=\(request.method), id=\(request.id)")
        print("[AgentWebSocketTransport] JSON payload: \(jsonString)")

        // Send the message
        let message = URLSessionWebSocketTask.Message.string(jsonString)
        try await task.send(message)
        print("[AgentWebSocketTransport] Request sent, waiting for response...")

        // Wait for response with timeout
        do {
            let response = try await withTimeout(ms: timeoutMs) {
                try await withCheckedThrowingContinuation { continuation in
                    Task {
                        await self.registerPendingRequest(id: request.id, continuation: continuation)
                    }
                }
            }
            print("[AgentWebSocketTransport] Received response for request \(request.id): \(response)")
            return response
        } catch {
            print("[AgentWebSocketTransport] ERROR: Request failed: \(error)")
            throw error
        }
    }

    // MARK: - Private Methods

    private func startReceiving(task: URLSessionWebSocketTask) {
        print("[AgentWebSocketTransport] 🎧 Starting receive loop, task state: \(task.state.rawValue)")
        readerTask = Task {
            var messageCount = 0
            while !Task.isCancelled {
                print("[AgentWebSocketTransport] 🔄 Waiting for message... (count: \(messageCount), cancelled: \(Task.isCancelled))")
                do {
                    let message = try await task.receive()
                    messageCount += 1
                    print("[AgentWebSocketTransport] 📥 Received message #\(messageCount)")
                    await handleMessage(message)
                } catch {
                    // Connection closed or error
                    print("[AgentWebSocketTransport] ❌ Receive error: \(error)")
                    await handleError(error)
                    break
                }
            }
            print("[AgentWebSocketTransport] 🛑 Receive loop ended after \(messageCount) messages")
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        guard case .string(let text) = message else {
            print("[AgentWebSocketTransport] Received non-string message, ignoring")
            return
        }

        do {
            let data = Data(text.utf8)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            // First, try to determine if this is a notification or a response
            // Notifications don't have an "id" field
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if json["id"] == nil && json["method"] != nil {
                    // This is a notification
                    let method = json["method"] as? String ?? "unknown"
                    print("[AgentWebSocketTransport] 📩 Notification received: \(method)")
                    let notification = try decoder.decode(AgentNotification.self, from: data)
                    await handleNotification(notification)
                    return
                }
            }

            // Not a notification, try to decode as response
            let response = try decoder.decode(AgentResponse.self, from: data)
            print("[AgentWebSocketTransport] Response received for id=\(response.id)")

            // Find and resume the pending request
            if let continuation = pendingRequests.removeValue(forKey: response.id) {
                continuation.resume(returning: response)
            } else {
                print("[AgentWebSocketTransport] WARNING: No pending request for \(response.id)")
            }
        } catch {
            print("[AgentWebSocketTransport] ERROR: Failed to decode message: \(error)")
            print("[AgentWebSocketTransport] Message text: \(text.prefix(200))...")
        }
    }

    private func handleNotification(_ notification: AgentNotification) async {
        // Dispatch to handler on MainActor
        if let handler = notificationHandler {
            print("[AgentWebSocketTransport] 📤 Dispatching notification to handler: \(notification.method)")
            await handler.handleNotification(method: notification.method, params: notification.params)
        } else {
            print("[AgentWebSocketTransport] ⚠️ No notification handler set for: \(notification.method)")
        }
    }

    private func handleError(_ error: Error) async {
        let wasConnected = isConnected
        isConnected = false

        // Stop heartbeat
        heartbeatTask?.cancel()
        heartbeatTask = nil

        // Cancel all pending requests with error
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: AgentError.webSocketError(error.localizedDescription))
        }
        pendingRequests.removeAll()

        // Notify delegate of disconnection
        if wasConnected, let delegate = delegate {
            await delegate.transportDidDisconnect(error: error)
        }
    }

    private func startHeartbeat(task: URLSessionWebSocketTask) {
        heartbeatTask = Task {
            var missedPongs = 0

            while !Task.isCancelled && isConnected {
                // Wait for heartbeat interval
                try? await Task.sleep(nanoseconds: heartbeatIntervalMs * 1_000_000)

                guard !Task.isCancelled && isConnected else { break }

                // Send ping
                print("[AgentWebSocketTransport] 💓 Sending heartbeat ping")
                do {
                    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                        task.sendPing { error in
                            if let error = error {
                                cont.resume(throwing: error)
                            } else {
                                cont.resume()
                            }
                        }
                    }

                    // Pong received successfully
                    missedPongs = 0
                    lastPongTime = Date()
                    print("[AgentWebSocketTransport] 💓 Heartbeat pong received")

                } catch {
                    missedPongs += 1
                    print("[AgentWebSocketTransport] ⚠️ Heartbeat ping failed (missed: \(missedPongs)): \(error)")

                    if missedPongs >= missedPongThreshold {
                        print("[AgentWebSocketTransport] ❌ Connection stale, triggering disconnect")
                        await handleError(AgentError.connectionFailed("Heartbeat timeout"))
                        break
                    }
                }
            }
            print("[AgentWebSocketTransport] 💓 Heartbeat task ended")
        }
    }

    private func registerPendingRequest(id: String, continuation: CheckedContinuation<AgentResponse, Error>) {
        pendingRequests[id] = continuation
    }

    private func withTimeout<T: Sendable>(ms: UInt64, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: ms * 1_000_000)
                throw AgentError.timeout(ms)
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
