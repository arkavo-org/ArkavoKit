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
    private var pendingRequests: [JSONRPCID: CheckedContinuation<AgentResponse, Error>] = [:]

    private struct WeakNotificationHandler {
        weak var handler: (any AgentNotificationHandler)?
    }

    // Legacy single notification handler slot (kept for backwards compatibility)
    private weak var notificationHandler: (any AgentNotificationHandler)?

    // Multiplexed notification handlers keyed by ObjectIdentifier
    private var notificationHandlers: [ObjectIdentifier: WeakNotificationHandler] = [:]

    // Connection state delegate
    private weak var delegate: (any AgentWebSocketTransportDelegate)?

    // Configuration
    private let timeoutMs: UInt64
    private let requireTLS: Bool
    private let authToken: String?

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
        missedPongThreshold: Int = 2,
        authToken: String? = nil
    ) {
        self.timeoutMs = timeoutMs
        self.requireTLS = requireTLS
        self.heartbeatIntervalMs = heartbeatIntervalMs
        self.missedPongThreshold = missedPongThreshold
        self.authToken = authToken
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

        // Clean up any existing session, tasks, and pending requests before reconnecting
        heartbeatTask?.cancel()
        heartbeatTask = nil

        readerTask?.cancel()
        readerTask = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        session?.invalidateAndCancel()
        session = nil

        isConnected = false

        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: AgentError.connectionFailed("Reconnecting"))
        }
        pendingRequests.removeAll()

        // Create URL session configuration
        // Keep timeoutIntervalForResource at its long default so persistent WebSockets are not killed
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Double(timeoutMs) / 1000.0

        let session = URLSession(configuration: configuration)
        self.session = session

        // Create WebSocket task (attaching Authorization header when configured)
        let request = makeWebSocketRequest(for: url)
        let task = session.webSocketTask(with: request)
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
            if self.webSocketTask === task {
                self.webSocketTask = nil
                self.session = nil
                self.endpoint = nil
            }
            throw error
        }

        // Verify this connection attempt was not superseded or closed while awaiting sendPing
        guard self.webSocketTask === task else {
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            throw AgentError.connectionFailed("Connection superseded or closed during handshake")
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

    /// Set the legacy primary notification handler
    public func setNotificationHandler(_ handler: (any AgentNotificationHandler)?) {
        self.notificationHandler = handler
    }

    /// Clear the notification handler only if it matches the given handler instance
    public func clearNotificationHandler(ifMatching handler: any AgentNotificationHandler) {
        let targetId = ObjectIdentifier(handler as AnyObject)
        if let current = notificationHandler,
           ObjectIdentifier(current as AnyObject) == targetId {
            notificationHandler = nil
        }
        notificationHandlers.removeValue(forKey: targetId)
    }

    /// Register a notification handler without displacing other registered handlers
    public func addNotificationHandler(_ handler: any AgentNotificationHandler) {
        pruneDeadNotificationHandlers()
        let id = ObjectIdentifier(handler as AnyObject)
        notificationHandlers[id] = WeakNotificationHandler(handler: handler)
    }

    /// Unregister a previously registered notification handler
    public func removeNotificationHandler(_ handler: any AgentNotificationHandler) {
        let id = ObjectIdentifier(handler as AnyObject)
        notificationHandlers.removeValue(forKey: id)
        if let current = notificationHandler,
           ObjectIdentifier(current as AnyObject) == id {
            notificationHandler = nil
        }
    }

    /// Current legacy primary notification handler (internal for testing)
    func getNotificationHandler() -> (any AgentNotificationHandler)? {
        notificationHandler
    }

    /// Current active notification handlers across legacy and multiplexed slots (internal for testing)
    func getNotificationHandlers() -> [any AgentNotificationHandler] {
        pruneDeadNotificationHandlers()
        var active: [any AgentNotificationHandler] = []
        var seen = Set<ObjectIdentifier>()

        if let primary = notificationHandler {
            let id = ObjectIdentifier(primary as AnyObject)
            seen.insert(id)
            active.append(primary)
        }

        for (id, box) in notificationHandlers {
            if let handler = box.handler, !seen.contains(id) {
                seen.insert(id)
                active.append(handler)
            }
        }

        return active
    }

    private func pruneDeadNotificationHandlers() {
        notificationHandlers = notificationHandlers.filter { $0.value.handler != nil }
    }

    /// Build a WebSocket upgrade `URLRequest` with optional bearer token auth
    nonisolated static func makeWebSocketRequest(for url: URL, authToken: String?) -> URLRequest {
        var request = URLRequest(url: url)
        if let authToken, !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func makeWebSocketRequest(for url: URL) -> URLRequest {
        Self.makeWebSocketRequest(for: url, authToken: authToken)
    }

    // MARK: - Request/Response

    /// Send a JSON-RPC request and await the response
    public func sendRequest(_ request: AgentRequest) async throws -> AgentResponse {
        guard isConnected, webSocketTask != nil else {
            print("[AgentWebSocketTransport] ERROR: Not connected")
            throw AgentError.notConnected
        }

        let rpcId = request.rpcId
        guard pendingRequests[rpcId] == nil else {
            print("[AgentWebSocketTransport] ERROR: Duplicate pending request id: \(request.id)")
            throw AgentError.webSocketError("Duplicate pending request id: \(request.id)")
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

        let timeout = timeoutMs

        // Register pending request before sending and enforce timeout with cancellation support
        do {
            let response = try await withTimeout(ms: timeout) {
                try await self.sendAndAwaitResponse(requestId: rpcId, jsonString: jsonString)
            }
            print("[AgentWebSocketTransport] Received response for request \(request.id): \(response)")
            return response
        } catch {
            print("[AgentWebSocketTransport] ERROR: Request failed: \(error)")
            throw error
        }
    }

    // MARK: - Private Methods

    private func sendAndAwaitResponse(requestId: JSONRPCID, jsonString: String) async throws -> AgentResponse {
        try Task.checkCancellation()
        guard isConnected, let task = webSocketTask else {
            throw AgentError.notConnected
        }
        guard pendingRequests[requestId] == nil else {
            throw AgentError.webSocketError("Duplicate pending request id: \(requestId.stringValue)")
        }

        let message = URLSessionWebSocketTask.Message.string(jsonString)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard self.isConnected, self.webSocketTask === task else {
                    continuation.resume(throwing: AgentError.notConnected)
                    return
                }
                guard self.pendingRequests[requestId] == nil else {
                    continuation.resume(throwing: AgentError.webSocketError("Duplicate pending request id: \(requestId.stringValue)"))
                    return
                }

                // Register synchronously on actor BEFORE sending so fast replies are never missed
                self.pendingRequests[requestId] = continuation

                task.send(message) { [weak self] error in
                    guard let error, let self else { return }
                    let errorMessage = error.localizedDescription
                    Task {
                        await self.cancelPendingRequest(
                            id: requestId,
                            error: AgentError.webSocketError(errorMessage)
                        )
                    }
                }
            }
        } onCancel: {
            Task {
                await self.cancelPendingRequest(id: requestId, error: CancellationError())
            }
        }
    }

    private func cancelPendingRequest(id: JSONRPCID, error: Error) {
        if let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }

    private func startReceiving(task: URLSessionWebSocketTask) {
        print("[AgentWebSocketTransport] 🎧 Starting receive loop, task state: \(task.state.rawValue)")
        readerTask = Task {
            var messageCount = 0
            while !Task.isCancelled {
                print("[AgentWebSocketTransport] 🔄 Waiting for message... (count: \(messageCount), cancelled: \(Task.isCancelled))")
                do {
                    let message = try await task.receive()
                    guard self.webSocketTask === task else { break }
                    messageCount += 1
                    print("[AgentWebSocketTransport] 📥 Received message #\(messageCount)")
                    await handleMessage(message)
                } catch {
                    // Connection closed or error
                    print("[AgentWebSocketTransport] ❌ Receive error: \(error)")
                    await handleError(error, for: task)
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

            // Not a notification, try to decode as response while preserving JSON-RPC id type
            let envelope = try decoder.decode(AgentResponseEnvelope.self, from: data)
            let response = envelope.response
            print("[AgentWebSocketTransport] Response received for id=\(response.id)")

            // Find and resume the pending request matching exact JSON-RPC id type
            if let continuation = pendingRequests.removeValue(forKey: envelope.rpcId) {
                continuation.resume(returning: response)
            } else {
                print("[AgentWebSocketTransport] WARNING: No pending request for \(response.id)")
            }
        } catch {
            print("[AgentWebSocketTransport] ERROR: Failed to decode message: \(error)")
            print("[AgentWebSocketTransport] Message text: \(text.prefix(200))...")
        }
    }

    func handleNotification(_ notification: AgentNotification) async {
        let handlers = getNotificationHandlers()
        guard !handlers.isEmpty else {
            print("[AgentWebSocketTransport] ⚠️ No notification handler set for: \(notification.method)")
            return
        }
        print("[AgentWebSocketTransport] 📤 Dispatching notification to \(handlers.count) handler(s): \(notification.method)")
        for handler in handlers {
            await handler.handleNotification(method: notification.method, params: notification.params)
        }
    }

    private func handleError(_ error: Error, for task: URLSessionWebSocketTask) async {
        // Ignore stale errors from superseded connections
        guard self.webSocketTask === task else {
            return
        }

        let wasConnected = isConnected
        isConnected = false

        // Stop heartbeat and reader
        heartbeatTask?.cancel()
        heartbeatTask = nil

        readerTask?.cancel()
        readerTask = nil

        // Tear down WebSocket task and session to prevent leaks
        webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
        webSocketTask = nil

        session?.invalidateAndCancel()
        session = nil

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

            while !Task.isCancelled && isConnected && self.webSocketTask === task {
                // Wait for heartbeat interval
                let (nanos, overflow) = heartbeatIntervalMs.multipliedReportingOverflow(by: 1_000_000)
                try? await Task.sleep(nanoseconds: overflow ? UInt64.max : nanos)

                guard !Task.isCancelled && isConnected && self.webSocketTask === task else { break }

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
                        await handleError(AgentError.connectionFailed("Heartbeat timeout"), for: task)
                        break
                    }
                }
            }
            print("[AgentWebSocketTransport] 💓 Heartbeat task ended")
        }
    }

    private func withTimeout<T: Sendable>(ms: UInt64, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                let (nanos, overflow) = ms.multipliedReportingOverflow(by: 1_000_000)
                try await Task.sleep(nanoseconds: overflow ? UInt64.max : nanos)
                throw AgentError.timeout(ms)
            }

            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }
}
