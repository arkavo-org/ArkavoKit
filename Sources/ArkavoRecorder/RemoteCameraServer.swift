@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Network

@MainActor
public protocol RemoteCameraServerDelegate: AnyObject {
    func remoteCameraServer(_ server: RemoteCameraServer, didReceiveFrame buffer: CMSampleBuffer, sourceID: String)
    func remoteCameraServer(_ server: RemoteCameraServer, didReceive metadata: CameraMetadataEvent)
    func remoteCameraServer(_ server: RemoteCameraServer, didUpdateSources sources: [String])
}

/// Lightweight TCP server that ingests remote camera frames + metadata encoded as NDJSON `RemoteCameraMessage`s.
public final class RemoteCameraServer: NSObject, @unchecked Sendable {
    public static let serviceType = RemoteCameraConstants.serviceType

    private let queue = DispatchQueue(label: "com.arkavo.remote-camera-server")
    private var listener: NWListener?
    private var connections: [UUID: ConnectionState] = [:]
    private var netService: NetService?
    private var serviceName: String?
    private var videoDecoders: [String: VideoStreamDecoder] = [:]  // sourceID -> decoder

    public weak var delegate: RemoteCameraServerDelegate?
    public private(set) var port: UInt16 = 0

    private struct ConnectionState {
        let id: UUID
        let connection: NWConnection
        var buffer = Data()
        var sourceID: String?
    }

    public override init() {
        super.init()
    }

    public func start(port: UInt16 = 0, serviceName: String? = nil) throws {
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

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.port = listener.port?.rawValue ?? port
                print("✅ [RemoteCameraServer] TCP listener ready on port \(self.port)")
                self.publishBonjourService()
            case .failed(let error):
                print("❌ [RemoteCameraServer] Listener failed: \(error)")
            case .cancelled:
                print("🛑 [RemoteCameraServer] Listener cancelled")
            default:
                break
            }
        }

        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil

        for (_, connection) in connections {
            connection.connection.cancel()
        }
        connections.removeAll()
        netService?.stop()
        netService = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.remoteCameraServer(self, didUpdateSources: [])
        }
    }

    private func publishBonjourService() {
        netService?.stop()
        guard let name = serviceName else { return }

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
        netService = service
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let id = UUID()
        var state = ConnectionState(id: id, connection: connection)
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
        if let state = connections[id], let sourceID = state.sourceID {
            updateSources(removing: sourceID)
            // Clean up decoder for this source
            videoDecoders[sourceID]?.invalidate()
            videoDecoders.removeValue(forKey: sourceID)
        }
        connections[id]?.connection.cancel()
        connections.removeValue(forKey: id)
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

            self.receive(on: connection, id: id)
        }
    }

    private func append(data: Data, to id: UUID) {
        guard var state = connections[id] else { return }
        state.buffer.append(data)

        while let newlineRange = state.buffer.firstRange(of: Data([0x0A])) {
            let packet = state.buffer.subdata(in: 0 ..< newlineRange.lowerBound)
            state.buffer.removeSubrange(0 ... newlineRange.lowerBound)
            processPacket(packet, from: id, state: &state)
        }

        connections[id] = state
    }

    private func processPacket(_ data: Data, from id: UUID, state: inout ConnectionState) {
        guard !data.isEmpty else { return }
        do {
            let message = try JSONDecoder().decode(RemoteCameraMessage.self, from: data)
            switch message.kind {
            case .handshake:
                if let sourceID = message.handshake?.sourceID {
                    state.sourceID = sourceID
                    updateSources(adding: sourceID)
                }
            case .videoNALU:
                guard let naluPayload = message.videoNALU else { return }
                state.sourceID = naluPayload.sourceID
                updateSources(adding: naluPayload.sourceID)

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
                state.sourceID = event.sourceID
                updateSources(adding: event.sourceID)
                print("📊 [RemoteCameraServer] Received metadata from \(event.sourceID)")
                if case .arFace(let faceMetadata) = event.metadata {
                    print("   └─ Face metadata: \(faceMetadata.blendShapes.count) blend shapes")
                    // Log first few blend shapes as a sample
                    let sampleShapes = faceMetadata.blendShapes.prefix(3)
                    for (name, value) in sampleShapes {
                        print("      └─ \(name): \(String(format: "%.3f", value))")
                    }
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    print("📤 [RemoteCameraServer] Forwarding metadata to delegate")
                    self.delegate?.remoteCameraServer(self, didReceive: event)
                }
            case .audio:
                guard let audioPayload = message.audio else { return }
                state.sourceID = audioPayload.sourceID
                updateSources(adding: audioPayload.sourceID)
                // TODO: Implement audio sample buffer handling and delegate call
                print("🎤 Received audio: \(audioPayload.audioData.count) bytes at \(audioPayload.sampleRate)Hz")
            }

            connections[id] = state
        } catch {
            print("⚠️ RemoteCameraServer decode error: \(error)")
        }
    }

    private func updateSources(adding id: String? = nil, removing removedID: String? = nil) {
        var sources = Set<String>()
        for state in connections.values {
            if let sourceID = state.sourceID {
                sources.insert(sourceID)
            }
        }
        if let removedID {
            sources.remove(removedID)
        }
        if let id {
            sources.insert(id)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.delegate?.remoteCameraServer(self, didUpdateSources: Array(sources))
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
