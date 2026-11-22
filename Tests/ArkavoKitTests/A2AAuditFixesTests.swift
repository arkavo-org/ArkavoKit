import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import ArkavoA2A
import ArkavoSocial

final class A2AAuditFixesTests: XCTestCase {

    // MARK: - AgentResponse / AgentRequest / AgentNotification (L-A2A-2 & JSON-RPC Interop)

    func test_agentResponse_decodesErrorBeforeResultWhenBothPresent() throws {
        let json = """
        {"jsonrpc":"2.0","id":"req-1","result":null,"error":{"code":-32600,"message":"Invalid Request"}}
        """
        let response = try JSONDecoder().decode(AgentResponse.self, from: Data(json.utf8))

        guard case .error(let id, let code, let message) = response else {
            XCTFail("Expected .error response when error object is present alongside null result")
            return
        }
        XCTAssertEqual(id, "req-1")
        XCTAssertEqual(code, -32600)
        XCTAssertEqual(message, "Invalid Request")
    }

    func test_agentResponse_decodesSuccessWhenErrorIsNull() throws {
        let json = """
        {"jsonrpc":"2.0","id":"req-2","error":null,"result":{"ok":true}}
        """
        let response = try JSONDecoder().decode(AgentResponse.self, from: Data(json.utf8))

        guard case .success(let id, let result) = response else {
            XCTFail("Expected .success response when error is null")
            return
        }
        XCTAssertEqual(id, "req-2")
        let dict = result.value as? [String: Any]
        XCTAssertEqual(dict?["ok"] as? Bool, true)
    }

    func test_agentResponse_decodesNumericId() throws {
        let successJSON = """
        {"jsonrpc":"2.0","id":42,"result":{"status":"ok"}}
        """
        let successResponse = try JSONDecoder().decode(AgentResponse.self, from: Data(successJSON.utf8))
        XCTAssertEqual(successResponse.id, "42")
        XCTAssertTrue(successResponse.isSuccess)

        let errorJSON = """
        {"jsonrpc":"2.0","id":99,"error":{"code":-32601,"message":"Method not found"}}
        """
        let errorResponse = try JSONDecoder().decode(AgentResponse.self, from: Data(errorJSON.utf8))
        XCTAssertEqual(errorResponse.id, "99")
        XCTAssertFalse(errorResponse.isSuccess)
    }

    func test_agentRequest_decodesNumericIdAndOptionalParams() throws {
        let json = """
        {"jsonrpc":"2.0","method":"ping","id":7}
        """
        let request = try JSONDecoder().decode(AgentRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.jsonrpc, "2.0")
        XCTAssertEqual(request.method, "ping")
        XCTAssertEqual(request.id, "7")
        XCTAssertEqual(request.numericId, 7)
        XCTAssertTrue(request.params.value is NSNull)
    }

    @MainActor
    func test_jsonRpcNumericId_roundTripsAsJsonNumber() async throws {
        let numericRequestJSON = """
        {"jsonrpc":"2.0","method":"chat_open","id":7}
        """
        let numericRequest = try JSONDecoder().decode(AgentRequest.self, from: Data(numericRequestJSON.utf8))
        XCTAssertEqual(numericRequest.id, "7")
        XCTAssertEqual(numericRequest.numericId, 7)

        // AgentRequest re-encodes numeric id as JSON number 7 (not string "7")
        let encodedRequestData = try JSONEncoder().encode(numericRequest)
        let encodedRequestJSON = try XCTUnwrap(String(data: encodedRequestData, encoding: .utf8))
        let requestObj = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedRequestData) as? [String: Any])
        XCTAssertEqual(requestObj["id"] as? Int, 7)
        XCTAssertNil(requestObj["id"] as? String)
        XCTAssertTrue(encodedRequestJSON.contains("\"id\":7"))
        XCTAssertFalse(encodedRequestJSON.contains("\"id\":\"7\""))

        // String id "7" stays a JSON string (not coerced to number)
        let stringRequestJSON = """
        {"jsonrpc":"2.0","method":"ping","id":"7"}
        """
        let stringRequest = try JSONDecoder().decode(AgentRequest.self, from: Data(stringRequestJSON.utf8))
        XCTAssertEqual(stringRequest.id, "7")
        XCTAssertNil(stringRequest.numericId)
        let encodedStringRequestData = try JSONEncoder().encode(stringRequest)
        let stringRequestObj = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedStringRequestData) as? [String: Any])
        XCTAssertEqual(stringRequestObj["id"] as? String, "7")
        XCTAssertNil(stringRequestObj["id"] as? Int)

        // AgentResponseEnvelope round-trips numeric id: 7 as JSON number 7
        let numericResponseJSON = """
        {"jsonrpc":"2.0","id":7,"result":{"ok":true}}
        """
        let envelope = try JSONDecoder().decode(AgentResponseEnvelope.self, from: Data(numericResponseJSON.utf8))
        XCTAssertEqual(envelope.rpcId, .int(7))
        XCTAssertEqual(envelope.response.id, "7")
        let reencodedEnvelopeData = try JSONEncoder().encode(envelope)
        let reencodedEnvelopeObj = try XCTUnwrap(JSONSerialization.jsonObject(with: reencodedEnvelopeData) as? [String: Any])
        XCTAssertEqual(reencodedEnvelopeObj["id"] as? Int, 7)
        XCTAssertNil(reencodedEnvelopeObj["id"] as? String)

        // LocalAIAgent response echoes numeric id: 7 as JSON number 7 (not "7")
        let response = try await LocalAIAgent.shared.processRequest(numericRequest)
        let encodedResponseData = try LocalAIAgent.shared.encodeResponse(response, rpcId: numericRequest.rpcId)
        let encodedResponseJSON = try XCTUnwrap(String(data: encodedResponseData, encoding: .utf8))
        let responseObj = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedResponseData) as? [String: Any])
        XCTAssertEqual(responseObj["id"] as? Int, 7)
        XCTAssertNil(responseObj["id"] as? String)
        XCTAssertTrue(encodedResponseJSON.contains("\"id\":7"))
        XCTAssertFalse(encodedResponseJSON.contains("\"id\":\"7\""))
    }

    func test_agentNotification_decodesWithoutParams() throws {
        let json = """
        {"jsonrpc":"2.0","method":"heartbeat"}
        """
        let notification = try JSONDecoder().decode(AgentNotification.self, from: Data(json.utf8))
        XCTAssertEqual(notification.jsonrpc, "2.0")
        XCTAssertEqual(notification.method, "heartbeat")
        XCTAssertTrue(notification.params.value is NSNull)
    }

    // MARK: - SensorBridge.validateRate (L-A2A-1)

    @MainActor
    func test_sensorBridge_validateRate_rejectsNonPositiveAndExcessiveRates() {
        let bridge = SensorBridge()

        XCTAssertFalse(bridge.validateRate(0.0, for: .motion))
        XCTAssertFalse(bridge.validateRate(-1.0, for: .motion))
        XCTAssertFalse(bridge.validateRate(-0.0001, for: .location))
        XCTAssertFalse(bridge.validateRate(.nan, for: .compass))
        XCTAssertFalse(bridge.validateRate(.infinity, for: .camera))
        XCTAssertFalse(bridge.validateRate(100.1, for: .motion))
        XCTAssertFalse(bridge.validateRate(1.5, for: .location))

        XCTAssertTrue(bridge.validateRate(0.5, for: .location))
        XCTAssertTrue(bridge.validateRate(1.0, for: .location))
        XCTAssertTrue(bridge.validateRate(50.0, for: .motion))
        XCTAssertTrue(bridge.validateRate(100.0, for: .motion))
        XCTAssertTrue(bridge.validateRate(10.0, for: .compass))
    }

    // MARK: - AgentChatSessionManager Null/Primitive Result Handling (#58 & M-A2A-1)

    func test_agentChatSessionManager_handlesNullResultWithoutCrashing() {
        XCTAssertThrowsError(
            try AgentChatSessionManager.decodeChatSession(from: AnyCodable(NSNull()))
        ) { error in
            guard case AgentError.invalidResponse = error else {
                XCTFail("Expected AgentError.invalidResponse, got \(error)")
                return
            }
        }

        XCTAssertThrowsError(
            try AgentChatSessionManager.decodeChatSession(from: AnyCodable("not-an-object"))
        )

        let nullDeltaParams = AnyCodable(["subscription": "sub-1", "result": NSNull()])
        XCTAssertThrowsError(
            try AgentChatSessionManager.decodeMessageDelta(from: nullDeltaParams)
        ) { error in
            guard case AgentError.invalidResponse = error else {
                XCTFail("Expected AgentError.invalidResponse, got \(error)")
                return
            }
        }
    }

    func test_agentChatSessionManager_extractsServerSubscriptionId() throws {
        let stringSub = AgentChatSessionManager.extractSubscriptionId(from: AnyCodable("sub-abc"))
        XCTAssertEqual(stringSub?.value as? String, "sub-abc")

        let numericSub = try XCTUnwrap(
            AgentChatSessionManager.extractSubscriptionId(from: AnyCodable(12345))
        )
        XCTAssertEqual(numericSub.value as? Int, 12345)
        XCTAssertNil(numericSub.value as? String)

        // Verify positional unsubscribe params encode numeric subscription ID as JSON integer
        let unsubscribeData = try JSONEncoder().encode(AnyCodable([numericSub.value]))
        XCTAssertEqual(String(data: unsubscribeData, encoding: .utf8), "[12345]")

        let dictStringSub = AgentChatSessionManager.extractSubscriptionId(from: AnyCodable(["subscription": "sub-xyz"]))
        XCTAssertEqual(dictStringSub?.value as? String, "sub-xyz")

        let dictNumericSub = AgentChatSessionManager.extractSubscriptionId(from: AnyCodable(["subscription": 98765]))
        XCTAssertEqual(dictNumericSub?.value as? Int, 98765)
        XCTAssertNil(dictNumericSub?.value as? String)

        let dictSubIdNumeric = AgentChatSessionManager.extractSubscriptionId(from: AnyCodable(["subscription_id": 54321]))
        XCTAssertEqual(dictSubIdNumeric?.value as? Int, 54321)

        XCTAssertNil(
            AgentChatSessionManager.extractSubscriptionId(from: AnyCodable(NSNull()))
        )
    }

    // MARK: - AgentDiscoveryService IPv6 URL Formatting (#60)

    func test_agentDiscoveryService_formatsIPv6URLsAndZoneIDs() {
        XCTAssertEqual(
            AgentDiscoveryService.formatWebSocketURL(host: "fe80::1", isIPv6: true, port: 8080),
            "ws://[fe80::1]:8080"
        )
        XCTAssertEqual(
            AgentDiscoveryService.formatWebSocketURL(host: "fe80::1%en0", isIPv6: true, port: 8080),
            "ws://[fe80::1%25en0]:8080"
        )
        XCTAssertEqual(
            AgentDiscoveryService.formatWebSocketURL(host: "192.168.1.42", isIPv6: false, port: 9000),
            "ws://192.168.1.42:9000"
        )
        XCTAssertNil(
            AgentDiscoveryService.formatWebSocketURL(host: "fe80::1", isIPv6: true, port: 0)
        )
        XCTAssertNil(
            AgentDiscoveryService.formatWebSocketURL(host: "", isIPv6: false, port: 8080)
        )
    }

    func test_agentDiscoveryService_prefersIPv4OverIPv6AndRejectsInvalidSockaddr() {
        let ipv6Data = makeIPv6AddressData("2001:db8::1")
        let ipv4Data = makeIPv4AddressData("192.168.1.10")

        let preferred = AgentDiscoveryService.selectPreferredHost(from: [ipv6Data, ipv4Data])
        XCTAssertEqual(preferred?.host, "192.168.1.10")
        XCTAssertEqual(preferred?.isIPv6, false)

        let ipv6Only = AgentDiscoveryService.selectPreferredHost(from: [ipv6Data])
        XCTAssertEqual(ipv6Only?.host, "2001:db8::1")
        XCTAssertEqual(ipv6Only?.isIPv6, true)

        XCTAssertNil(AgentDiscoveryService.parseHostFromAddress(Data([0x00, 0x01])))
    }

    // MARK: - LocalAIAgent Non-Null Struct Encoding (C18) & ImagePlayground Availability (L-A2A-3)

    @MainActor
    func test_localAIAgent_encodesNonNullStructResults() async throws {
        let agent = LocalAIAgent.shared

        // Verify chat_open returns a non-null JSON object decodable as ChatSession
        let request = AgentRequest(method: "chat_open", params: AnyCodable([String: Any]()), id: "chat-open-1")
        let response = try await agent.processRequest(request)

        guard case .success(let id, let result) = response else {
            XCTFail("Expected .success response for chat_open")
            return
        }
        XCTAssertEqual(id, "chat-open-1")
        XCTAssertFalse(result.value is NSNull, "ChatSession result must not serialize as null")

        let decodedSession = try AgentChatSessionManager.decodeChatSession(from: result)
        XCTAssertFalse(decodedSession.id.isEmpty)
        XCTAssertEqual(decodedSession.capabilities?.supportedMessageTypes, ["text"])

        // Verify SensorResponse and ToolCallResult encode as non-null dictionaries
        let sensorResponse = SensorResponse(
            taskId: "task-1",
            payload: AnyCodable(["latitude": 37.77]),
            redactions: ["Removed altitude data"]
        )
        let encodedSensor = try agent.encodeToAnyCodable(sensorResponse)
        let sensorDict = encodedSensor.value as? [String: Any]
        XCTAssertEqual(sensorDict?["task_id"] as? String, "task-1")

        let toolResult = ToolCallResult(
            toolCallId: "tc-1",
            success: true,
            result: AnyCodable(["summary": "ok"])
        )
        let encodedTool = try agent.encodeToAnyCodable(toolResult)
        let toolDict = encodedTool.value as? [String: Any]
        XCTAssertEqual(toolDict?["tool_call_id"] as? String, "tc-1")
        XCTAssertEqual(toolDict?["success"] as? Bool, true)
    }

    @MainActor
    func test_imagePlaygroundIntegration_reportsUnavailableWhileStubbed() {
        let integration = ImagePlaygroundIntegration()
        XCTAssertFalse(integration.isAvailable)
    }

    // MARK: - PR #88 Review Regression Tests

    @MainActor
    func test_agentStreamHandler_unsubscribeDoesNotClearAnotherNotificationHandler() async {
        let endpoint = AgentEndpoint(
            id: "agent-shared",
            url: "ws://127.0.0.1:9999",
            metadata: AgentMetadata(name: "Test", purpose: "Test", model: "test")
        )
        let connection = AgentConnection(endpoint: endpoint)
        let otherHandler = DummyNotificationHandler()
        let streamHandler = AgentStreamHandler(sessionId: "session-1", connection: connection)

        // When another handler owns the connection, unsubscribing streamHandler must NOT clear it
        await connection.setNotificationHandler(otherHandler)
        await streamHandler.unsubscribe()

        let currentAfterOther = await connection.getNotificationHandler()
        XCTAssertNotNil(currentAfterOther)
        if let currentAfterOther {
            XCTAssertEqual(
                ObjectIdentifier(currentAfterOther as AnyObject),
                ObjectIdentifier(otherHandler as AnyObject)
            )
        }

        // When streamHandler itself is registered, unsubscribing clears it cleanly
        await connection.setNotificationHandler(streamHandler)
        await streamHandler.unsubscribe()

        let currentAfterSelf = await connection.getNotificationHandler()
        XCTAssertNil(currentAfterSelf)
    }

    @MainActor
    func test_localAIAgent_rejectsOversizedUnfragmentedMessages() {
        let agent = LocalAIAgent.shared
        let connectionId = UUID()

        // Unfragmented single-frame message exceeding 16 MiB must be rejected
        let oversized = Data(count: LocalAIAgent.maxMessageSize + 1)
        XCTAssertEqual(
            agent.accumulateFrame(oversized, isComplete: true, for: connectionId),
            .rejectOversized
        )

        // Normal unfragmented message is delivered
        let validPayload = Data(#"{"jsonrpc":"2.0","method":"ping","id":1}"#.utf8)
        XCTAssertEqual(
            agent.accumulateFrame(validPayload, isComplete: true, for: connectionId),
            .deliver(validPayload)
        )

        // Fragmented message exceeding 16 MiB across two frames is also rejected
        let halfPlusOne = Data(count: (LocalAIAgent.maxMessageSize / 2) + 1)
        let fragmentedConnId = UUID()
        XCTAssertEqual(
            agent.accumulateFrame(halfPlusOne, isComplete: false, for: fragmentedConnId),
            .buffered
        )
        XCTAssertEqual(
            agent.accumulateFrame(halfPlusOne, isComplete: true, for: fragmentedConnId),
            .rejectOversized
        )
    }

    func test_agentWebSocketTransport_attachesBearerAuthHeaderWhenConfigured() throws {
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:8080"))

        let authedRequest = AgentWebSocketTransport.makeWebSocketRequest(for: url, authToken: "secret-token")
        XCTAssertEqual(authedRequest.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")

        let unauthedRequest = AgentWebSocketTransport.makeWebSocketRequest(for: url, authToken: nil)
        XCTAssertNil(unauthedRequest.value(forHTTPHeaderField: "Authorization"))

        let emptyTokenRequest = AgentWebSocketTransport.makeWebSocketRequest(for: url, authToken: "")
        XCTAssertNil(emptyTokenRequest.value(forHTTPHeaderField: "Authorization"))
    }

    @MainActor
    func test_agentManager_initialConnectFailure_reconnectionAndCleanup() async {
        let invalidEndpoint = AgentEndpoint(
            id: "unreachable-agent",
            url: "http://not-a-websocket",
            metadata: AgentMetadata(name: "Unreachable", purpose: "Test", model: "test")
        )

        // When autoReconnect == true, initial failure starts reconnection with .reconnecting(attempt: 1)
        let retryingManager = AgentManager(autoConnect: false, autoReconnect: true)
        do {
            try await retryingManager.connect(to: invalidEndpoint)
            XCTFail("Expected initial connect to fail for invalid WebSocket URL")
        } catch {
            // Expected
        }
        XCTAssertNotNil(retryingManager.connections[invalidEndpoint.id])
        XCTAssertEqual(retryingManager.statuses[invalidEndpoint.id], .reconnecting(attempt: 1))
        await retryingManager.disconnectAll()

        // When autoReconnect == false, initial failure removes the failed connection so future retries aren't blocked
        let nonRetryingManager = AgentManager(autoConnect: false, autoReconnect: false)
        do {
            try await nonRetryingManager.connect(to: invalidEndpoint)
            XCTFail("Expected initial connect to fail for invalid WebSocket URL")
        } catch {
            // Expected
        }
        XCTAssertNil(nonRetryingManager.connections[invalidEndpoint.id])
        if case .failed? = nonRetryingManager.statuses[invalidEndpoint.id] {
            // Expected
        } else {
            XCTFail("Expected .failed status when autoReconnect is false, got \(String(describing: nonRetryingManager.statuses[invalidEndpoint.id]))")
        }
    }

    // MARK: - Helpers

    @MainActor
    private final class DummyNotificationHandler: AgentNotificationHandler {
        func handleNotification(method: String, params: AnyCodable) async {}
    }

    private func makeIPv4AddressData(_ ip: String) -> Data {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        _ = inet_pton(AF_INET, ip, &addr.sin_addr)
        return withUnsafeBytes(of: &addr) { Data($0) }
    }

    private func makeIPv6AddressData(_ ip: String) -> Data {
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        _ = inet_pton(AF_INET6, ip, &addr.sin6_addr)
        return withUnsafeBytes(of: &addr) { Data($0) }
    }
}
