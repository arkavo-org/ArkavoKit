@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Network
import os

@MainActor
public protocol RemoteCameraServerDelegate: AnyObject {
    func remoteCameraServer(_ server: RemoteCameraServer, didReceiveFrame buffer: CMSampleBuffer, sourceID: String)
    func remoteCameraServer(_ server: RemoteCameraServer, didReceive metadata: CameraMetadataEvent)
    func remoteCameraServer(_ server: RemoteCameraServer, didUpdateSources sources: [String])
    func remoteCameraServer(_ server: RemoteCameraServer, didReceiveAudio payload: RemoteCameraMessage.AudioPayload, sourceID: String)
}

public extension RemoteCameraServerDelegate {
    func remoteCameraServer(_ server: RemoteCameraServer, didReceiveAudio payload: RemoteCameraMessage.AudioPayload, sourceID: String) {}
}

/// Lightweight TCP server that ingests remote camera frames + metadata encoded as NDJSON `RemoteCameraMessage`s.
public final class RemoteCameraServer: NSObject, @unchecked Sendable {
    public static let serviceType = RemoteCameraConstants.serviceType

    private let queue = DispatchQueue(label: "com.arkavo.remote-camera-server")
    private let queueKey = DispatchSpecificKey<Void>()
    private var listener: NWListener?
    private var connections: [UUID: ConnectionState] = [:]
    /// Only mutated/accessed on `DispatchQueue.main` so `NetService` runs on `RunLoop.main`.
    private var netService: NetService?
    private var serviceName: String?
    private var videoDecoders: [String: VideoStreamDecoder] = [:]  // sourceID -> decoder

    private let _port = OSAllocatedUnfairLock<UInt16>(initialState: 0)
    private let bonjourGeneration = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    public weak var delegate: RemoteCameraServerDelegate?
    public var port: UInt16 {
        _port.withLock { $0 }
    }

    private struct ConnectionState {
        let id: UUID
        let connection: NWConnection
        var framer = NDJSONFramer(maxMessageSize: RemoteCameraConstants.maxMessageSize)
        var sourceID: String?
    }

    public override init() {
        super.init()
        queue.setSpecific(key: queueKey, value: ())
    }

    private func onQueueSync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try work()
        }
        return try queue.sync(execute: work)
    }

    public func start(port: UInt16 = 0, serviceName: String? = nil) throws {
        try onQueueSync {
            guard listener == nil else { return }

            if port == 0 {
                print("🚀 [RemoteCameraServer] Starting TCP listener on dynamic port...")
            } else {
                print("🚀 [RemoteCameraServer] Starting TCP listener on port \(port)...")
            }

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let nwPort: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
            let listener = try NWListener(using: parameters, on: nwPort)
            self.listener = listener

            #if os(macOS)
                self.serviceName = serviceName ?? Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            #else
                self.serviceName = serviceName ?? ProcessInfo.processInfo.hostName
            #endif

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                switch state {
                case .ready:
                    let boundPort = listener.port?.rawValue ?? port
                    self._port.withLock { $0 = boundPort }
                    print("✅ [RemoteCameraServer] TCP listener ready on port \(boundPort)")
                    if let name = self.serviceName {
                        let generation = self.bonjourGeneration.withLock { gen -> UInt64 in
                            gen &+= 1
                            return gen
                        }
                        self.publishBonjourService(name: name, port: boundPort, generation: generation)
                    }
                case .failed(let error):
                    print("❌ [RemoteCameraServer] Listener failed: \(error)")
                    if self.listener === listener {
                        self.listener = nil
                    }
                    self._port.withLock { $0 = 0 }
                case .cancelled:
                    print("🛑 [RemoteCameraServer] Listener cancelled")
                    if self.listener === listener {
                        self.listener = nil
                    }
                    self._port.withLock { $0 = 0 }
                default:
                    break
                }
            }

            listener.start(queue: queue)
        }
    }

    public func stop() {
        bonjourGeneration.withLock { $0 &+= 1 }

        onQueueSync {
            listener?.cancel()
            listener = nil
            _port.withLock { $0 = 0 }

            for (_, state) in connections {
                state.connection.cancel()
            }
            connections.removeAll()

            for (_, decoder) in videoDecoders {
                decoder.invalidate()
            }
            videoDecoders.removeAll()
        }

        DispatchQueue.main.async { [weak self] in
            self?.netService?.stop()
            self?.netService = nil
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.remoteCameraServer(self, didUpdateSources: [])
        }
    }

    private func publishBonjourService(name: String, port: UInt16, generation: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.bonjourGeneration.withLock({ $0 }) == generation else { return }

            self.netService?.stop()

            print("🔊 [Bonjour] Publishing service '\(name)' on port \(port)")
            print("   Type: \(Self.serviceType)")
            print("   Domain: local.")
            print("   Options: includesPeerToPeer (no listenForConnections - we have our own NWListener)")

            let service = NetService(domain: "local.", type: Self.serviceType, name: name, port: Int32(port))
            service.includesPeerToPeer = true
            service.delegate = self
            // Don't use .listenForConnections - we already have our own NWListener
            // NetService is only for discovery/advertisement
            service.publish(options: [])
            self.netService = service
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        // Peers are unauthenticated, so bound how many the server holds state for
        guard connections.count < RemoteCameraConstants.maxConnections else {
            print("⚠️ RemoteCameraServer: refusing connection, \(RemoteCameraConstants.maxConnections) already open")
            connection.cancel()
            return
        }
        let id = UUID()
        let state = ConnectionState(id: id, connection: connection)
        connections[id] = state

        connection.stateUpdateHandler = { [weak self] nwState in
            guard let self else { return }
            if case .failed = nwState {
                self.cleanupConnection(id: id)
            } else if case .cancelled = nwState {
                self.cleanupConnection(id: id)
            }
        }

        connection.start(queue: queue)
        receive(on: connection, id: id)
    }

    private func cleanupConnection(id: UUID) {
        // Remove connection first so shared sourceID checks see only remaining active connections.
        guard let state = connections.removeValue(forKey: id) else { return }
        state.connection.cancel()

        if let sourceID = state.sourceID {
            cleanupOrphanedDecoder(for: sourceID)
            updateSources()
        }
    }

    /// Invalidates and removes `videoDecoders[sourceID]` only if no active connection still owns `sourceID`.
    private func cleanupOrphanedDecoder(for sourceID: String) {
        let stillOwned = connections.values.contains { $0.sourceID == sourceID }
        if !stillOwned {
            videoDecoders.removeValue(forKey: sourceID)?.invalidate()
        }
    }

    /// Associates a connection with `sourceID`, cleaning up any previous source's orphaned decoder
    /// (keeping total decoders bounded by `RemoteCameraConstants.maxConnections`).
    private func assignSourceID(_ newSourceID: String, for connectionID: UUID, state: inout ConnectionState) {
        let previousSourceID = state.sourceID
        state.sourceID = newSourceID
        connections[connectionID] = state

        if let previousSourceID, previousSourceID != newSourceID {
            cleanupOrphanedDecoder(for: previousSourceID)
        }
        updateSources()
    }

    private func receive(on connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: RemoteCameraConstants.maxReceiveBufferSize) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.append(data: data, to: id)
            }

            if let error {
                print("⚠️ RemoteCameraServer connection error: \(error)")
                self.cleanupConnection(id: id)
                return
            }

            if isComplete {
                self.cleanupConnection(id: id)
                return
            }

            // `append` closes a connection that broke the message limit
            guard self.connections[id] != nil else { return }
            self.receive(on: connection, id: id)
        }
    }

    private func append(data: Data, to id: UUID) {
        guard var state = connections[id] else { return }
        let packets: [Data]
        do {
            packets = try state.framer.append(data)
        } catch {
            print("⚠️ RemoteCameraServer: closing connection, a message exceeded \(RemoteCameraConstants.maxMessageSize) bytes")
            cleanupConnection(id: id)
            return
        }

        for packet in packets {
            processPacket(packet, from: id, state: &state)
        }

        if connections[id] != nil {
            connections[id] = state
        }
    }

    private func processPacket(_ data: Data, from id: UUID, state: inout ConnectionState) {
        guard !data.isEmpty else { return }
        do {
            let message = try JSONDecoder().decode(RemoteCameraMessage.self, from: data)
            switch message.kind {
            case .handshake:
                if let sourceID = message.handshake?.sourceID {
                    assignSourceID(sourceID, for: id, state: &state)
                }
            case .videoNALU:
                guard let naluPayload = message.videoNALU else { return }
                assignSourceID(naluPayload.sourceID, for: id, state: &state)

                // Get or create decoder for this source
                let decoder: VideoStreamDecoder
                if let existingDecoder = self.videoDecoders[naluPayload.sourceID] {
                    decoder = existingDecoder
                } else {
                    let newDecoder = VideoStreamDecoder { [weak self] pixelBuffer, timestamp in
                        // Create sample buffer from decoded pixel buffer
                        guard let sampleBuffer = self?.createSampleBuffer(from: pixelBuffer, timestamp: timestamp) else {
                            return
                        }
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.delegate?.remoteCameraServer(self, didReceiveFrame: sampleBuffer, sourceID: naluPayload.sourceID)
                        }
                    }
                    newDecoder.start()
                    self.videoDecoders[naluPayload.sourceID] = newDecoder
                    decoder = newDecoder
                }

                // Decode H.264 NAL unit
                let timestamp = CMTime(seconds: naluPayload.timestamp, preferredTimescale: RemoteCameraConstants.videoTimescale)
                try? decoder.decode(naluPayload.naluData, isKeyFrame: naluPayload.isKeyFrame, timestamp: timestamp)
            case .metadata:
                guard let event = message.metadata else { return }
                assignSourceID(event.sourceID, for: id, state: &state)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.delegate?.remoteCameraServer(self, didReceive: event)
                }
            case .audio:
                guard let audioPayload = message.audio else { return }
                assignSourceID(audioPayload.sourceID, for: id, state: &state)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.delegate?.remoteCameraServer(self, didReceiveAudio: audioPayload, sourceID: audioPayload.sourceID)
                }
            }
        } catch {
            print("⚠️ RemoteCameraServer decode error: \(error)")
        }
    }

    private func updateSources() {
        var sources = Set<String>()
        for state in connections.values {
            if let sourceID = state.sourceID {
                sources.insert(sourceID)
            }
        }
        let sortedSources = Array(sources)
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.remoteCameraServer(self, didUpdateSources: sortedSources)
        }
    }

    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: timestamp,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        var formatDescription: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else { return nil }

        let result = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        guard result == noErr else { return nil }
        return sampleBuffer
    }
}

extension RemoteCameraServer: NetServiceDelegate {
    public func netServiceDidPublish(_ sender: NetService) {
        print("✅ [Bonjour] Service published successfully!")
        print("   Name: \(sender.name)")
        print("   Type: \(sender.type)")
        print("   Domain: \(sender.domain)")
        print("   Port: \(sender.port)")
        if let addresses = sender.addresses, !addresses.isEmpty {
            print("   Addresses: \(addresses.count) address(es)")
        }
        print("💡 [Bonjour] iOS devices should now be able to discover this Mac")
    }

    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        print("❌ [Bonjour] Publish failed!")
        print("   Service: \(sender.name)")
        print("   Error: \(errorDict)")
        if let domain = errorDict["NSNetServicesErrorDomain"],
           let code = errorDict["NSNetServicesErrorCode"] {
            print("   Domain: \(domain), Code: \(code)")
            if code.intValue == -72004 {
                print("   → Error -72004: Name conflict - another service with same name exists")
            } else if code.intValue == -72003 {
                print("   → Error -72003: Invalid argument")
            }
        }
    }
}
