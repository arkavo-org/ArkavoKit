import Foundation
import Network

// MARK: - Local HTTP Server

/// Local HTTP server for serving fMP4/HLS content to AVPlayer
///
/// AVPlayer's HLS + FairPlay pipeline requires HTTP delivery. This server
/// provides proper HTTP semantics including byte-range support.
public final class LocalHTTPServer: @unchecked Sendable {

    // MARK: - Types

    public enum ServerError: Error, LocalizedError {
        case startFailed(Error)
        case startTimeout
        case notStarted

        public var errorDescription: String? {
            switch self {
            case .startFailed(let error):
                return "Failed to start HTTP server: \(error.localizedDescription)"
            case .startTimeout:
                return "HTTP server startup timed out"
            case .notStarted:
                return "HTTP server not started"
            }
        }
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        var rangeStart: Int?
        var rangeEnd: Int?
    }

    // MARK: - Properties

    private let contentDirectory: URL
    private let queue = DispatchQueue(label: "com.arkavo.LocalHTTPServer")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var startupError: Error?

    public private(set) var port: UInt16 = 0

    /// Base URL for the server (e.g., http://127.0.0.1:8080)
    public var baseURL: URL? {
        guard port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    // MARK: - Initialization

    /// Initialize server with content directory
    /// - Parameter contentDirectory: Directory containing files to serve
    public init(contentDirectory: URL) {
        self.contentDirectory = contentDirectory
    }

    deinit {
        stop()
    }

    // MARK: - Server Control

    /// Start the HTTP server
    /// - Returns: Base URL of the server
    /// - Throws: ServerError if start fails
    @discardableResult
    public func start() throws -> URL {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        // Bind to localhost only for security
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )

        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw ServerError.startFailed(error)
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
                print("🌐 HTTP server listening on port \(self.port)")
                semaphore.signal()
            case .failed(let error):
                print("🌐 HTTP server failed: \(error.localizedDescription)")
                self.startupError = error
                semaphore.signal()
            case .cancelled:
                print("🌐 HTTP server cancelled")
            default:
                break
            }
        }

        listener?.start(queue: queue)

        // Wait for listener to be ready
        let result = semaphore.wait(timeout: .now() + 5)

        if result == .timedOut {
            listener?.cancel()
            listener = nil
            throw ServerError.startTimeout
        }

        if let error = startupError {
            listener?.cancel()
            listener = nil
            throw ServerError.startFailed(error)
        }

        guard let url = baseURL else {
            throw ServerError.notStarted
        }

        return url
    }

    /// Stop the HTTP server and clean up all connections
    public func stop() {
        // Cancel all connections
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()

        // Cancel listener
        listener?.cancel()
        listener = nil
        port = 0

        print("🌐 HTTP server stopped")
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        queue.async { [weak self] in
            self?.connections[connectionID] = connection
        }

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async {
                    self?.connections.removeValue(forKey: connectionID)
                }
            default:
                break
            }
        }

        connection.start(queue: queue)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
            guard let self = self else { return }

            if let error = error {
                print("🌐 Receive error: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            guard let data = data, let requestString = String(data: data, encoding: .utf8) else {
                self.sendResponse(to: connection, status: 400, statusText: "Bad Request", body: nil)
                return
            }

            self.handleHTTPRequest(requestString, on: connection)
        }
    }

    // MARK: - HTTP Request Handling

    private func handleHTTPRequest(_ requestString: String, on connection: NWConnection) {
        // Parse request
        guard let request = parseRequest(requestString) else {
            sendResponse(to: connection, status: 400, statusText: "Bad Request", body: nil)
            return
        }

        print("🌐 HTTP \(request.method) \(request.path)")

        // Only support GET and HEAD
        guard request.method == "GET" || request.method == "HEAD" else {
            sendResponse(to: connection, status: 405, statusText: "Method Not Allowed", body: nil)
            return
        }

        // Get filename from path (remove leading /)
        let filename = String(request.path.dropFirst())

        // Read file
        let fileURL = contentDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let fileData = try? Data(contentsOf: fileURL) else {
            print("🌐 HTTP 404 Not Found: \(filename)")
            sendResponse(to: connection, status: 404, statusText: "Not Found", body: nil)
            return
        }

        let contentType = mimeType(for: filename)
        let fullLength = fileData.count

        // Handle Range request
        if let rangeStart = request.rangeStart {
            let rangeEnd = min(request.rangeEnd ?? (fullLength - 1), fullLength - 1)

            // Validate range
            guard rangeStart >= 0, rangeStart < fullLength, rangeStart <= rangeEnd else {
                sendResponse(
                    to: connection,
                    status: 416,
                    statusText: "Range Not Satisfiable",
                    headers: ["Content-Range": "bytes */\(fullLength)"],
                    body: nil
                )
                return
            }

            let slice = fileData[rangeStart...rangeEnd]
            let sliceLength = slice.count

            print("🌐 HTTP 206 \(filename) bytes=\(rangeStart)-\(rangeEnd)/\(fullLength)")

            sendResponse(
                to: connection,
                status: 206,
                statusText: "Partial Content",
                headers: [
                    "Content-Type": contentType,
                    "Content-Length": "\(sliceLength)",
                    "Content-Range": "bytes \(rangeStart)-\(rangeEnd)/\(fullLength)",
                    "Accept-Ranges": "bytes"
                ],
                body: request.method == "HEAD" ? nil : Data(slice)
            )
        } else {
            // Full file response
            print("🌐 HTTP 200 \(filename) (\(fullLength) bytes)")

            sendResponse(
                to: connection,
                status: 200,
                statusText: "OK",
                headers: [
                    "Content-Type": contentType,
                    "Content-Length": "\(fullLength)",
                    "Accept-Ranges": "bytes"
                ],
                body: request.method == "HEAD" ? nil : fileData
            )
        }
    }

    // MARK: - Request Parsing

    private func parseRequest(_ requestString: String) -> HTTPRequest? {
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        // Parse: GET /path HTTP/1.1
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        var pathString = String(parts[1])

        // Strip query string
        if let queryIndex = pathString.firstIndex(of: "?") {
            pathString = String(pathString[..<queryIndex])
        }

        // Percent-decode path
        let path = pathString.removingPercentEncoding ?? pathString

        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colonIndex = line.firstIndex(of: ":") {
                let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        // Parse Range header
        var rangeStart: Int?
        var rangeEnd: Int?

        if let rangeHeader = headers["range"] {
            // Format: bytes=start-end or bytes=start-
            let pattern = #"bytes=(\d+)-(\d*)"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: rangeHeader, range: NSRange(rangeHeader.startIndex..., in: rangeHeader)) {

                if let startRange = Range(match.range(at: 1), in: rangeHeader) {
                    rangeStart = Int(rangeHeader[startRange])
                }

                if let endRange = Range(match.range(at: 2), in: rangeHeader),
                   !rangeHeader[endRange].isEmpty {
                    rangeEnd = Int(rangeHeader[endRange])
                }
            }
        }

        return HTTPRequest(
            method: method,
            path: path,
            headers: headers,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd
        )
    }

    // MARK: - Response Sending

    private func sendResponse(
        to connection: NWConnection,
        status: Int,
        statusText: String,
        headers: [String: String] = [:],
        body: Data?
    ) {
        var response = "HTTP/1.1 \(status) \(statusText)\r\n"

        // Add headers
        var allHeaders = headers
        allHeaders["Connection"] = "close"

        for (key, value) in allHeaders {
            response += "\(key): \(value)\r\n"
        }

        response += "\r\n"

        // Build response data
        var responseData = Data(response.utf8)
        if let body = body {
            responseData.append(body)
        }

        connection.send(content: responseData, completion: .contentProcessed { [weak self] error in
            if let error = error {
                print("🌐 Send error: \(error.localizedDescription)")
            }
            connection.cancel()
        })
    }

    // MARK: - MIME Types

    private func mimeType(for filename: String) -> String {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        switch ext {
        case "m3u8":
            return "application/vnd.apple.mpegurl"
        case "mp4":
            return "video/mp4"
        case "m4s":
            return "video/iso.segment"
        case "m4v":
            return "video/mp4"
        case "m4a":
            return "audio/mp4"
        case "mov":
            return "video/quicktime"
        case "ts":
            return "video/MP2T"
        default:
            return "application/octet-stream"
        }
    }
}
