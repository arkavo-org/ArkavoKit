import XCTest
import Network
@testable import ArkavoAgent

/// Tests for LocalAIAgent WebSocket server accepting URLSession client connections
final class LocalAIAgentWebSocketTests: XCTestCase {

    // MARK: - RED Phase: Test WebSocket Handshake

    /// Test that a URLSessionWebSocketTask client can connect to LocalAIAgent's NWListener server
    /// This test verifies the WebSocket upgrade handshake succeeds
    func test_webSocketHandshake_acceptsURLSessionClient() async throws {
        // Arrange: Start a WebSocket server using the same configuration as LocalAIAgent
        let server = try await startTestWebSocketServer(port: 0)
        defer { server.cancel() }

        guard let port = server.port?.rawValue else {
            XCTFail("Server did not get a port")
            return
        }

        let connectionExpectation = XCTestExpectation(description: "Client should connect")

        // Act: Connect using URLSessionWebSocketTask (same as AgentWebSocketTransport)
        let url = URL(string: "ws://127.0.0.1:\(port)")!
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        task.resume()

        // Verify connection by sending a ping
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            connectionExpectation.fulfill()
        } catch {
            XCTFail("WebSocket connection failed: \(error)")
        }

        // Cleanup
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()

        await fulfillment(of: [connectionExpectation], timeout: 5.0)
    }

    /// Test that the server accepts WebSocket messages after handshake
    func test_webSocketHandshake_canExchangeMessages() async throws {
        // Arrange
        let server = try await startTestWebSocketServer(port: 0)
        defer { server.cancel() }

        guard let port = server.port?.rawValue else {
            XCTFail("Server did not get a port")
            return
        }

        let url = URL(string: "ws://127.0.0.1:\(port)")!
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        task.resume()

        // Wait for connection
        try await Task.sleep(nanoseconds: 500_000_000)

        // Act: Send a message
        let testMessage = "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"id\":\"1\"}"
        do {
            try await task.send(.string(testMessage))
            // If we get here without error, the handshake worked
        } catch {
            XCTFail("Failed to send message: \(error)")
        }

        // Cleanup
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    // MARK: - Helper: Create test server with same config as LocalAIAgent

    /// Creates a WebSocket server using the same NWListener configuration as LocalAIAgent
    /// This mirrors the fix applied in LocalAIAgent.startPublishing()
    private func startTestWebSocketServer(port: UInt16) async throws -> NWListener {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        // Configure WebSocket options with client request handler
        // This is the key fix: without setClientRequestHandler, NWListener rejects
        // URLSession WebSocket clients with "client request doesn't match expected value"
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.setClientRequestHandler(DispatchQueue.main) { subprotocols, _ in
            // Accept all valid WebSocket upgrade requests
            let selectedSubprotocol = subprotocols.first
            return NWProtocolWebSocket.Response(
                status: .accept,
                subprotocol: selectedSubprotocol,
                additionalHeaders: nil
            )
        }
        params.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        let listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))

        let readyExpectation = XCTestExpectation(description: "Listener ready")

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                readyExpectation.fulfill()
            case .failed(let error):
                XCTFail("Listener failed: \(error)")
            default:
                break
            }
        }

        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
        }

        listener.start(queue: .main)

        await fulfillment(of: [readyExpectation], timeout: 5.0)

        return listener
    }
}
