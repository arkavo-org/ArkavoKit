#if os(macOS)
import Foundation
import Network

/// A lightweight HTTP server for handling OAuth redirects on localhost (macOS only)
public final class OAuthCallbackServer: @unchecked Sendable {
    public enum OAuthError: Error, LocalizedError {
        case serverStartFailed(Error)
        case invalidRequest
        case missingAuthorizationCode
        case stateMismatch
        case timeout
        case cancelled
        case oauthError(String)

        public var errorDescription: String? {
            switch self {
            case let .serverStartFailed(error):
                "Failed to start OAuth server: \(error.localizedDescription)"
            case .invalidRequest:
                "Invalid OAuth callback request"
            case .missingAuthorizationCode:
                "Authorization code missing from callback"
            case .stateMismatch:
                "OAuth state parameter mismatch - possible CSRF attack"
            case .timeout:
                "OAuth flow timed out"
            case .cancelled:
                "OAuth flow was cancelled"
            case let .oauthError(message):
                "OAuth error: \(message)"
            }
        }
    }

    private static let queueKey = DispatchSpecificKey<Void>()
    private static let maxHeaderBytes = 16 * 1024
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.arkavo.oauth-callback-server")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionBuffers: [ObjectIdentifier: Data] = [:]
    private var continuation: CheckedContinuation<String, Error>?
    private var pendingResult: Result<String, Error>?
    private var isCompleted = false
    private var timeoutWorkItem: DispatchWorkItem?
    private var expectedState: String?
    private var startupError: Error?
    private var startupSignaled = false
    private var _port: UInt16 = 0

    public var port: UInt16 {
        syncOnQueue { _port }
    }

    public var redirectUri: String {
        "http://127.0.0.1:\(port)"
    }

    public init() {
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit {
        stop()
    }

    private func syncOnQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return body()
        }
        return queue.sync(execute: body)
    }

    /// Start listening on 127.0.0.1 with an ephemeral port and configure expected CSRF state.
    /// Returns the bound port once the listener is `.ready`.
    @discardableResult
    public func startListening(state: String) throws -> UInt16 {
        syncOnQueue {
            stopListenerAndConnectionsLocked()
            expectedState = state
            isCompleted = false
            pendingResult = nil
            startupError = nil
            startupSignaled = false
            _port = 0
        }

        try startListener()
        return port
    }

    /// Wait for the OAuth callback on a server already started with `startListening(state:)`.
    public func waitForCallback(timeout: TimeInterval = 300) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                let alreadyCancelled = Task.isCancelled
                queue.async { [weak self] in
                    guard let self else {
                        cont.resume(throwing: OAuthError.cancelled)
                        return
                    }

                    if alreadyCancelled {
                        self.finishLocked(with: .failure(OAuthError.cancelled), delayConnectionCleanup: false)
                        self.pendingResult = nil
                        cont.resume(throwing: OAuthError.cancelled)
                        return
                    }

                    if let pending = self.pendingResult {
                        self.pendingResult = nil
                        cont.resume(with: pending)
                        return
                    }

                    if self.isCompleted {
                        cont.resume(throwing: OAuthError.cancelled)
                        return
                    }

                    self.continuation = cont

                    let workItem = DispatchWorkItem { [weak self] in
                        self?.finishLocked(with: .failure(OAuthError.timeout), delayConnectionCleanup: false)
                    }
                    self.timeoutWorkItem?.cancel()
                    self.timeoutWorkItem = workItem
                    self.queue.asyncAfter(deadline: .now() + timeout, execute: workItem)
                }
            }
        } onCancel: { [weak self] in
            guard let server = self else { return }
            server.queue.async { [weak server] in
                server?.finishLocked(with: .failure(OAuthError.cancelled), delayConnectionCleanup: false)
            }
        }
    }

    /// Start the server and wait for OAuth callback
    /// - Parameter state: The state parameter to validate against CSRF
    /// - Parameter timeout: Maximum time to wait for callback (default 5 minutes)
    /// - Returns: The authorization code from the OAuth callback
    public func startAndWaitForCallback(state: String, timeout: TimeInterval = 300) async throws -> String {
        _ = try startListening(state: state)
        return try await waitForCallback(timeout: timeout)
    }

    private func startListener() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            throw OAuthError.serverStartFailed(error)
        }

        let semaphore = DispatchSemaphore(value: 0)

        syncOnQueue {
            listener = newListener
            startupError = nil
            startupSignaled = false
            _port = 0
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        newListener.stateUpdateHandler = { [weak self, weak newListener] state in
            guard let self, let newListener else { return }
            guard self.listener === newListener else { return }
            switch state {
            case .ready:
                self._port = newListener.port?.rawValue ?? 0
                print("[OAuthCallbackServer] Listening on port \(self._port)")
                if !self.startupSignaled {
                    self.startupSignaled = true
                    semaphore.signal()
                }
            case let .failed(error):
                print("[OAuthCallbackServer] Listener failed: \(error)")
                self.startupError = error
                if !self.startupSignaled {
                    self.startupSignaled = true
                    semaphore.signal()
                }
            case .cancelled:
                print("[OAuthCallbackServer] Listener cancelled")
                if !self.startupSignaled {
                    self.startupSignaled = true
                    semaphore.signal()
                }
            default:
                break
            }
        }

        newListener.start(queue: queue)

        // Wait for listener to be ready (with timeout)
        let result = semaphore.wait(timeout: .now() + 5)

        if result == .timedOut {
            syncOnQueue {
                if listener === newListener {
                    stopListenerAndConnectionsLocked()
                }
            }
            throw OAuthError.serverStartFailed(NSError(
                domain: "OAuthCallbackServer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Listener startup timed out"]
            ))
        }

        let startOutcome: (error: Error?, ready: Bool) = syncOnQueue {
            if let error = startupError {
                if listener === newListener {
                    stopListenerAndConnectionsLocked()
                }
                return (error, false)
            }
            let isReady = (listener === newListener) && newListener.state == .ready && _port > 0
            if !isReady && listener === newListener {
                stopListenerAndConnectionsLocked()
            }
            return (nil, isReady)
        }

        if let error = startOutcome.error {
            throw OAuthError.serverStartFailed(error)
        }

        guard startOutcome.ready else {
            throw OAuthError.serverStartFailed(NSError(
                domain: "OAuthCallbackServer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Listener failed to start"]
            ))
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        connections[connectionID] = connection
        connectionBuffers[connectionID] = Data()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections.removeValue(forKey: connectionID)
                self?.connectionBuffers.removeValue(forKey: connectionID)
            default:
                break
            }
        }

        connection.start(queue: queue)
        receiveRequest(on: connection, id: connectionID)
    }

    private func receiveRequest(on connection: NWConnection, id connectionID: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHeaderBytes) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("[OAuthCallbackServer] Receive error: \(error)")
                self.connectionBuffers.removeValue(forKey: connectionID)
                connection.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                var buffer = self.connectionBuffers[connectionID] ?? Data()
                if buffer.count + data.count > Self.maxHeaderBytes {
                    self.connectionBuffers.removeValue(forKey: connectionID)
                    self.sendErrorResponse(to: connection, message: "Request headers too large")
                    return
                }
                buffer.append(data)
                self.connectionBuffers[connectionID] = buffer

                if let headerEnd = buffer.range(of: Self.headerTerminator) {
                    self.connectionBuffers.removeValue(forKey: connectionID)
                    let headerData = buffer[..<headerEnd.upperBound]
                    guard let request = String(data: headerData, encoding: .utf8) else {
                        self.sendErrorResponse(to: connection, message: "Invalid request")
                        return
                    }
                    self.handleHTTPRequest(request, on: connection)
                    return
                }
            }

            if isComplete {
                let remaining = self.connectionBuffers.removeValue(forKey: connectionID) ?? Data()
                if remaining.isEmpty {
                    connection.cancel()
                } else {
                    self.sendErrorResponse(to: connection, message: "Incomplete HTTP request")
                }
                return
            }

            self.receiveRequest(on: connection, id: connectionID)
        }
    }

    private func handleHTTPRequest(_ request: String, on connection: NWConnection) {
        // Parse HTTP request line: "GET /path?query HTTP/1.1"
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendErrorResponse(to: connection, message: "Invalid HTTP request")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendErrorResponse(to: connection, message: "Invalid HTTP request line")
            return
        }

        let pathAndQuery = parts[1]

        // Parse query parameters
        guard let url = URL(string: "http://127.0.0.1\(pathAndQuery)"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            sendErrorResponse(to: connection, message: "Invalid request URL")
            return
        }

        let queryItems = components.queryItems ?? []
        let hasCode = queryItems.contains(where: { $0.name == "code" })
        let hasError = queryItems.contains(where: { $0.name == "error" })

        // Ignore browser side requests (e.g., /favicon.ico) without aborting the OAuth flow.
        if components.path == "/favicon.ico" || (!hasCode && !hasError && components.path != "/" && !components.path.isEmpty) {
            sendNotFoundResponse(to: connection)
            return
        }

        // Check for error response from OAuth provider
        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            let errorDescription = queryItems.first(where: { $0.name == "error_description" })?.value ?? error
            sendErrorResponse(to: connection, message: errorDescription)
            finishLocked(with: .failure(OAuthError.oauthError(errorDescription)), delayConnectionCleanup: true)
            return
        }

        // Validate state parameter (CSRF protection) — MUST be present and match expectedState
        guard let expectedState = self.expectedState,
              let state = queryItems.first(where: { $0.name == "state" })?.value,
              state == expectedState
        else {
            sendErrorResponse(to: connection, message: "Invalid or missing state parameter")
            finishLocked(with: .failure(OAuthError.stateMismatch), delayConnectionCleanup: true)
            return
        }

        // Extract authorization code
        guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            sendErrorResponse(to: connection, message: "Missing authorization code")
            finishLocked(with: .failure(OAuthError.missingAuthorizationCode), delayConnectionCleanup: true)
            return
        }

        // Send success response
        sendSuccessResponse(to: connection)

        // Complete the continuation with the code
        finishLocked(with: .success(code), delayConnectionCleanup: true)
    }

    private func finishLocked(with result: Result<String, Error>, delayConnectionCleanup: Bool) {
        guard !isCompleted else { return }
        isCompleted = true

        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        if let cont = continuation {
            continuation = nil
            cont.resume(with: result)
        } else {
            pendingResult = result
        }

        // Stop accepting new connections immediately
        listener?.cancel()
        listener = nil
        _port = 0

        if delayConnectionCleanup {
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.cancelAllConnectionsLocked()
            }
        } else {
            cancelAllConnectionsLocked()
        }
    }

    private func sendNotFoundResponse(to connection: NWConnection) {
        let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendSuccessResponse(to connection: NWConnection) {
        let html = """
            <!DOCTYPE html>
            <html>
            <head>
                <title>Authorization Successful</title>
                <style>
                    body {
                        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                        display: flex;
                        justify-content: center;
                        align-items: center;
                        min-height: 100vh;
                        margin: 0;
                        background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                    }
                    .container {
                        text-align: center;
                        padding: 40px;
                        background: white;
                        border-radius: 16px;
                        box-shadow: 0 10px 40px rgba(0,0,0,0.2);
                    }
                    .checkmark {
                        font-size: 64px;
                        margin-bottom: 20px;
                    }
                    h1 {
                        color: #333;
                        margin-bottom: 10px;
                    }
                    p {
                        color: #666;
                        margin-bottom: 20px;
                    }
                    .close-note {
                        font-size: 14px;
                        color: #999;
                    }
                </style>
            </head>
            <body>
                <div class="container">
                    <div class="checkmark">✓</div>
                    <h1>Authorization Successful!</h1>
                    <p>You have successfully connected your YouTube account.</p>
                    <p class="close-note">You can close this window and return to ArkavoCreator.</p>
                </div>
                <script>
                    setTimeout(function() {
                        window.close();
                    }, 3000);
                </script>
            </body>
            </html>
            """

        let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(html.utf8.count)\r
            Connection: close\r
            \r
            \(html)
            """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    internal static func htmlEscape(_ string: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(string.count)
        for char in string {
            switch char {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(char)
            }
        }
        return escaped
    }

    private func sendErrorResponse(to connection: NWConnection, message: String) {
        let escapedMessage = Self.htmlEscape(message)
        let html = """
            <!DOCTYPE html>
            <html>
            <head>
                <title>Authorization Failed</title>
                <style>
                    body {
                        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                        display: flex;
                        justify-content: center;
                        align-items: center;
                        min-height: 100vh;
                        margin: 0;
                        background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
                    }
                    .container {
                        text-align: center;
                        padding: 40px;
                        background: white;
                        border-radius: 16px;
                        box-shadow: 0 10px 40px rgba(0,0,0,0.2);
                    }
                    .error-icon {
                        font-size: 64px;
                        margin-bottom: 20px;
                    }
                    h1 {
                        color: #333;
                        margin-bottom: 10px;
                    }
                    p {
                        color: #666;
                    }
                    .error-message {
                        background: #fee;
                        border: 1px solid #fcc;
                        border-radius: 8px;
                        padding: 15px;
                        margin-top: 20px;
                        color: #c00;
                    }
                </style>
            </head>
            <body>
                <div class="container">
                    <div class="error-icon">✗</div>
                    <h1>Authorization Failed</h1>
                    <p>There was a problem connecting your YouTube account.</p>
                    <div class="error-message">\(escapedMessage)</div>
                    <p>Please close this window and try again.</p>
                </div>
            </body>
            </html>
            """

        let response = """
            HTTP/1.1 400 Bad Request\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(html.utf8.count)\r
            Connection: close\r
            \r
            \(html)
            """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    public func stop() {
        syncOnQueue {
            finishLocked(with: .failure(OAuthError.cancelled), delayConnectionCleanup: false)
            stopListenerAndConnectionsLocked()
        }
    }

    private func stopListenerAndConnectionsLocked() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        listener?.cancel()
        listener = nil
        _port = 0
        cancelAllConnectionsLocked()
    }

    private func cancelAllConnectionsLocked() {
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()
        connectionBuffers.removeAll()
    }
}
#endif
