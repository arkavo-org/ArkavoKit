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

    // MARK: - Constants

    private static let queueKey = DispatchSpecificKey<Void>()
    private static let maxHeaderBytes = 16 * 1024
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    // MARK: - Properties

    private let contentDirectory: URL
    private let queue = DispatchQueue(label: "com.arkavo.LocalHTTPServer")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var connectionBuffers: [ObjectIdentifier: Data] = [:]
    private var startupError: Error?
    private var startupSignaled = false
    private var _port: UInt16 = 0

    public var port: UInt16 {
        syncOnQueue { _port }
    }

    /// Base URL for the server (e.g., http://127.0.0.1:8080)
    public var baseURL: URL? {
        let currentPort = port
        guard currentPort > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(currentPort)")
    }

    // MARK: - Initialization

    /// Initialize server with content directory
    /// - Parameter contentDirectory: Directory containing files to serve
    public init(contentDirectory: URL) {
        self.contentDirectory = contentDirectory
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    deinit {
        stop()
    }

    // MARK: - Synchronization

    private func syncOnQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            return body()
        }
        return queue.sync(execute: body)
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

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            throw ServerError.startFailed(error)
        }

        let semaphore = DispatchSemaphore(value: 0)

        syncOnQueue {
            stopLocked()
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
                print("🌐 HTTP server listening on port \(self._port)")
                if !self.startupSignaled {
                    self.startupSignaled = true
                    semaphore.signal()
                }
            case .failed(let error):
                print("🌐 HTTP server failed: \(error.localizedDescription)")
                self.startupError = error
                if !self.startupSignaled {
                    self.startupSignaled = true
                    semaphore.signal()
                }
            case .cancelled:
                print("🌐 HTTP server cancelled")
                if !self.startupSignaled {
                    self.startupSignaled = true
                    semaphore.signal()
                }
            default:
                break
            }
        }

        newListener.start(queue: queue)

        // Wait for listener to be ready
        let result = semaphore.wait(timeout: .now() + 5)

        if result == .timedOut {
            syncOnQueue {
                if listener === newListener {
                    stopLocked()
                }
            }
            throw ServerError.startTimeout
        }

        let startOutcome: (error: Error?, port: UInt16) = syncOnQueue {
            if let error = startupError {
                if listener === newListener {
                    stopLocked()
                }
                return (error, 0)
            }
            return (nil, _port)
        }

        if let error = startOutcome.error {
            throw ServerError.startFailed(error)
        }

        guard startOutcome.port > 0, let url = URL(string: "http://127.0.0.1:\(startOutcome.port)") else {
            throw ServerError.notStarted
        }

        return url
    }

    /// Stop the HTTP server and clean up all connections
    public func stop() {
        syncOnQueue {
            stopLocked()
        }
        print("🌐 HTTP server stopped")
    }

    private func stopLocked() {
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()
        connectionBuffers.removeAll()

        listener?.cancel()
        listener = nil
        _port = 0
        startupError = nil
    }

    // MARK: - Connection Handling

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
                print("🌐 Receive error: \(error.localizedDescription)")
                self.connectionBuffers.removeValue(forKey: connectionID)
                connection.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                var buffer = self.connectionBuffers[connectionID] ?? Data()
                if buffer.count + data.count > Self.maxHeaderBytes {
                    self.connectionBuffers.removeValue(forKey: connectionID)
                    self.sendResponse(
                        to: connection,
                        status: 431,
                        statusText: "Request Header Fields Too Large",
                        body: nil
                    )
                    return
                }
                buffer.append(data)
                self.connectionBuffers[connectionID] = buffer

                if let headerEnd = buffer.range(of: Self.headerTerminator) {
                    self.connectionBuffers.removeValue(forKey: connectionID)
                    let headerData = buffer[..<headerEnd.upperBound]
                    guard let requestString = String(data: headerData, encoding: .utf8) else {
                        self.sendResponse(to: connection, status: 400, statusText: "Bad Request", body: nil)
                        return
                    }
                    self.handleHTTPRequest(requestString, on: connection)
                    return
                }
            }

            if isComplete {
                let remaining = self.connectionBuffers.removeValue(forKey: connectionID) ?? Data()
                if remaining.isEmpty {
                    connection.cancel()
                } else {
                    self.sendResponse(to: connection, status: 400, statusText: "Bad Request", body: nil)
                }
                return
            }

            self.receiveRequest(on: connection, id: connectionID)
        }
    }

    // MARK: - Path Resolution

    private enum ResolvedFile {
        case file(URL, relativePath: String)
        case forbidden
        case notFound
    }

    private func resolveRequestedFile(for path: String) -> ResolvedFile {
        guard path.hasPrefix("/") else {
            return .forbidden
        }

        let relativePath = String(path.dropFirst())
        guard !relativePath.isEmpty else {
            return .notFound
        }
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\0") else {
            return .forbidden
        }

        let canonicalRoot = contentDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"

        let resolvedURL = canonicalRoot
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedPath = resolvedURL.path

        guard resolvedPath.hasPrefix(rootPrefix), resolvedPath != canonicalRoot.path else {
            return .forbidden
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            return .notFound
        }

        return .file(resolvedURL, relativePath: relativePath)
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

        let fileURL: URL
        let filename: String
        switch resolveRequestedFile(for: request.path) {
        case let .file(url, relativePath):
            fileURL = url
            filename = relativePath
        case .forbidden:
            print("🌐 HTTP 403 Forbidden: \(request.path)")
            sendResponse(to: connection, status: 403, statusText: "Forbidden", body: nil)
            return
        case .notFound:
            print("🌐 HTTP 404 Not Found: \(request.path)")
            sendResponse(to: connection, status: 404, statusText: "Not Found", body: nil)
            return
        }

        // Determine file size from attributes without loading the entire file into memory
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSizeNumber = attributes[.size] as? NSNumber
        else {
            print("🌐 HTTP 404 Not Found: \(filename)")
            sendResponse(to: connection, status: 404, statusText: "Not Found", body: nil)
            return
        }

        let fullLength = fileSizeNumber.intValue
        let contentType = mimeType(for: filename)

        // Handle Range request
        if let rangeStart = request.rangeStart {
            let rangeEnd = fullLength > 0 ? min(request.rangeEnd ?? (fullLength - 1), fullLength - 1) : -1

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

            let requestedLength = rangeEnd - rangeStart + 1
            let body: Data?
            let actualLength: Int
            let actualRangeEnd: Int
            let actualTotalLength: Int
            if request.method == "HEAD" {
                body = nil
                actualLength = requestedLength
                actualRangeEnd = rangeEnd
                actualTotalLength = fullLength
            } else {
                guard let sliceData = readFileSlice(from: fileURL, offset: UInt64(rangeStart), length: requestedLength) else {
                    sendResponse(to: connection, status: 500, statusText: "Internal Server Error", body: nil)
                    return
                }
                if sliceData.isEmpty {
                    sendResponse(
                        to: connection,
                        status: 416,
                        statusText: "Range Not Satisfiable",
                        headers: ["Content-Range": "bytes */\(rangeStart)"],
                        body: nil
                    )
                    return
                }
                body = sliceData
                actualLength = sliceData.count
                actualRangeEnd = rangeStart + actualLength - 1
                actualTotalLength = actualLength < requestedLength ? (rangeStart + actualLength) : fullLength
            }

            print("🌐 HTTP 206 \(filename) bytes=\(rangeStart)-\(actualRangeEnd)/\(actualTotalLength)")

            sendResponse(
                to: connection,
                status: 206,
                statusText: "Partial Content",
                headers: [
                    "Content-Type": contentType,
                    "Content-Length": "\(actualLength)",
                    "Content-Range": "bytes \(rangeStart)-\(actualRangeEnd)/\(actualTotalLength)",
                    "Accept-Ranges": "bytes"
                ],
                body: body
            )
        } else {
            let body: Data?
            let contentLength: Int
            if request.method == "HEAD" {
                body = nil
                contentLength = fullLength
            } else {
                guard let fileData = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                    sendResponse(to: connection, status: 500, statusText: "Internal Server Error", body: nil)
                    return
                }
                body = fileData
                contentLength = fileData.count
            }

            // Full file response
            print("🌐 HTTP 200 \(filename) (\(contentLength) bytes)")

            sendResponse(
                to: connection,
                status: 200,
                statusText: "OK",
                headers: [
                    "Content-Type": contentType,
                    "Content-Length": "\(contentLength)",
                    "Accept-Ranges": "bytes"
                ],
                body: body
            )
        }
    }

    private func readFileSlice(from fileURL: URL, offset: UInt64, length: Int) -> Data? {
        guard length >= 0 else { return nil }
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            var buffer = Data()
            buffer.reserveCapacity(length)
            while buffer.count < length {
                let remaining = length - buffer.count
                guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                    break
                }
                buffer.append(chunk)
            }
            return buffer
        } catch {
            print("🌐 Read slice error: \(error.localizedDescription)")
            return nil
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
        guard let path = pathString.removingPercentEncoding else { return nil }

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

        connection.send(content: responseData, completion: .contentProcessed { error in
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
