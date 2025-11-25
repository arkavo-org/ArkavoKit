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

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.arkavo.oauth-callback-server")
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<String, Error>?
    private var expectedState: String?
    private var startupError: Error?

    public private(set) var port: UInt16 = 0

    public var redirectUri: String {
        "http://127.0.0.1:\(port)"
    }

    public init() {}

    /// Start the server and wait for OAuth callback
    /// - Parameter state: The state parameter to validate against CSRF
    /// - Parameter timeout: Maximum time to wait for callback (default 5 minutes)
    /// - Returns: The authorization code from the OAuth callback
    public func startAndWaitForCallback(state: String, timeout: TimeInterval = 300) async throws -> String {
        expectedState = state

        // Start the listener
        try startListener()

        // Wait for the callback with timeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                self.continuation = cont

                // Set up timeout
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self = self else { return }
                    if self.continuation != nil {
                        self.continuation?.resume(throwing: OAuthError.timeout)
                        self.continuation = nil
                        self.stop()
                    }
                }
            }
        } onCancel: {
            self.continuation?.resume(throwing: OAuthError.cancelled)
            self.continuation = nil
            self.stop()
        }
    }

    private func startListener() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: parameters, on: .any)
        } catch {
            throw OAuthError.serverStartFailed(error)
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        let semaphore = DispatchSemaphore(value: 0)
        startupError = nil

        listener?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.port = self.listener?.port?.rawValue ?? 0
                print("[OAuthCallbackServer] Listening on port \(self.port)")
                semaphore.signal()
            case let .failed(error):
                print("[OAuthCallbackServer] Listener failed: \(error)")
                self.startupError = error
                semaphore.signal()
            case .cancelled:
                print("[OAuthCallbackServer] Listener cancelled")
            default:
                break
            }
        }

        listener?.start(queue: queue)

        // Wait for listener to be ready (with timeout)
        let result = semaphore.wait(timeout: .now() + 5)

        if result == .timedOut {
            throw OAuthError.serverStartFailed(NSError(
                domain: "OAuthCallbackServer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Listener startup timed out"]
            ))
        }

        if let error = startupError {
            throw OAuthError.serverStartFailed(error)
        }

        guard listener?.state == .ready else {
            throw OAuthError.serverStartFailed(NSError(
                domain: "OAuthCallbackServer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Listener failed to start"]
            ))
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.connection = nil
            } else if case .cancelled = state {
                self?.connection = nil
            }
        }

        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self = self else { return }

            if let error = error {
                print("[OAuthCallbackServer] Receive error: \(error)")
                return
            }

            guard let data = data, let request = String(data: data, encoding: .utf8) else {
                self.sendErrorResponse(to: connection, message: "Invalid request")
                return
            }

            self.handleHTTPRequest(request, on: connection)
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
        guard let url = URL(string: "http://localhost\(pathAndQuery)"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            sendErrorResponse(to: connection, message: "Invalid request URL")
            return
        }

        let queryItems = components.queryItems ?? []

        // Check for error response from OAuth provider
        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            let errorDescription = queryItems.first(where: { $0.name == "error_description" })?.value ?? error
            sendErrorResponse(to: connection, message: errorDescription)
            continuation?.resume(throwing: OAuthError.oauthError(errorDescription))
            continuation = nil
            stop()
            return
        }

        // Validate state parameter (CSRF protection)
        if let state = queryItems.first(where: { $0.name == "state" })?.value {
            if state != expectedState {
                sendErrorResponse(to: connection, message: "Invalid state parameter")
                continuation?.resume(throwing: OAuthError.stateMismatch)
                continuation = nil
                stop()
                return
            }
        }

        // Extract authorization code
        guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
            sendErrorResponse(to: connection, message: "Missing authorization code")
            continuation?.resume(throwing: OAuthError.missingAuthorizationCode)
            continuation = nil
            stop()
            return
        }

        // Send success response
        sendSuccessResponse(to: connection)

        // Complete the continuation with the code
        continuation?.resume(returning: code)
        continuation = nil

        // Stop the server after a brief delay to ensure response is sent
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.stop()
        }
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

    private func sendErrorResponse(to connection: NWConnection, message: String) {
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
                    <div class="error-message">\(message)</div>
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
        listener?.cancel()
        listener = nil
        connection?.cancel()
        connection = nil
    }
}
#endif
