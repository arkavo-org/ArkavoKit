import Testing
import Foundation
import Network
@testable import ArkavoRecorder

/// The remote-camera server reads newline-delimited JSON from unauthenticated peers on
/// the local network, so what one peer can make it hold must be bounded.
struct NDJSONFramerTests {
    @Test("A message split across reads comes out once it is complete")
    func reassemblesSplitMessages() throws {
        var framer = NDJSONFramer(maxMessageSize: 16)
        #expect(try framer.append(Data("{\"a\":".utf8)) == [])
        #expect(try framer.append(Data("1}\n".utf8)) == [Data("{\"a\":1}".utf8)])
    }

    @Test("Several messages in one read all come out, in order")
    func splitsSeveralMessages() throws {
        var framer = NDJSONFramer(maxMessageSize: 16)
        #expect(try framer.append(Data("one\ntwo\nthr".utf8)) == [Data("one".utf8), Data("two".utf8)])
        #expect(try framer.append(Data("ee\n".utf8)) == [Data("three".utf8)])
    }

    @Test("Input with no newline past the limit is refused")
    func refusesAnUnterminatedMessagePastTheLimit() throws {
        var framer = NDJSONFramer(maxMessageSize: 16)
        _ = try framer.append(Data(repeating: 0x61, count: 16))
        #expect(throws: NDJSONFramer.MessageTooLarge.self) {
            try framer.append(Data([0x61]))
        }
    }

    @Test("A complete message longer than the limit is refused even when it arrives in one read")
    func refusesACompleteMessagePastTheLimit() {
        var framer = NDJSONFramer(maxMessageSize: 16)
        #expect(throws: NDJSONFramer.MessageTooLarge.self) {
            try framer.append(Data(repeating: 0x61, count: 17) + Data([0x0A]))
        }
    }
}

@Suite(.serialized)
struct RemoteCameraServerLimitsTests {
    @Test("A peer that sends more than the message limit without a newline is disconnected", .timeLimit(.minutes(1)))
    func oversizedMessageDisconnects() async throws {
        let server = try await Self.startServer()
        defer { server.stop() }

        let connection = try await Self.connect(to: server.port)
        defer { connection.cancel() }
        let unterminated = Data(repeating: 0x61, count: RemoteCameraConstants.maxMessageSize + 1)
        connection.send(content: unterminated, completion: .idempotent)

        #expect(await Self.isClosedByServer(connection, within: .seconds(10)))
    }

    @Test("Connections beyond the limit are refused", .timeLimit(.minutes(1)))
    func connectionsBeyondTheLimitAreRefused() async throws {
        let server = try await Self.startServer()
        defer { server.stop() }

        var open: [NWConnection] = []
        defer { open.forEach { $0.cancel() } }
        for _ in 0..<RemoteCameraConstants.maxConnections {
            open.append(try await Self.connect(to: server.port))
        }
        for connection in open {
            #expect(!(await Self.isClosedByServer(connection, within: .milliseconds(300))))
        }

        let extra = try await Self.connect(to: server.port)
        defer { extra.cancel() }
        #expect(await Self.isClosedByServer(extra, within: .seconds(10)))
    }

    // MARK: - Helpers

    private static func startServer() async throws -> RemoteCameraServer {
        let server = RemoteCameraServer()
        try server.start(port: 0, serviceName: "ArkavoKit test \(UUID().uuidString.prefix(8))")
        for _ in 0..<100 where server.port == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(server.port != 0, "server did not start listening")
        return server
    }

    private static func connect(to port: UInt16) async throws -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ready = Flag()
        connection.stateUpdateHandler = { state in
            if case .ready = state { ready.set() }
        }
        connection.start(queue: DispatchQueue(label: "remote-camera-test-client"))
        for _ in 0..<250 where !ready.value {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(ready.value, "could not connect to the server")
        return connection
    }

    /// Whether the server ends the connection (end of stream or an error) within `limit`
    private static func isClosedByServer(_ connection: NWConnection, within limit: Duration) async -> Bool {
        let closed = Flag()
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, isComplete, error in
                if isComplete || error != nil { closed.set() } else { receive() }
            }
        }
        receive()
        let deadline = ContinuousClock.now + limit
        while !closed.value, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return closed.value
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    var value: Bool { lock.withLock { isSet } }
    func set() { lock.withLock { isSet = true } }
}
