import AVFoundation
import CoreMedia
import os
import VideoToolbox

/// Hardware-accelerated H.264 video decoder for streaming
/// Uses VideoToolbox VTDecompressionSession for efficient decoding
public final class VideoStreamDecoder {
    // MARK: - Types

    /// Callback invoked when decoded frame is ready
    /// - Parameters:
    ///   - pixelBuffer: Decoded video frame, which the decoder keeps no reference to
    ///   - timestamp: Presentation timestamp
    public typealias OutputHandler = (sending CVPixelBuffer, CMTime) -> Void

    // MARK: - Properties

    private let sessionLock = NSLock()
    private var decompressionSession: VTDecompressionSession?
    private var sessionRefCon: Unmanaged<CallbackContext>?
    private var formatDescription: CMFormatDescription?
    private var cachedSPS: Data?
    private var cachedPPS: Data?
    private let outputHandler: OutputHandler
    private let outputQueue = DispatchQueue(label: "com.arkavo.video-stream-decoder")

    private var isDecoding = false

    /// Current active format description (exposed internally for testing)
    var currentFormatDescription: CMFormatDescription? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return formatDescription
    }

    // MARK: - Initialization

    public init(outputHandler: @escaping OutputHandler) {
        self.outputHandler = outputHandler
    }

    deinit {
        invalidate()
    }

    // MARK: - Public Methods

    /// Explicitly sets the H.264 format description, recreating the decompression session if needed.
    public func setFormatDescription(_ formatDescription: CMFormatDescription) {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        self.formatDescription = formatDescription
        if let session = decompressionSession,
           !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: formatDescription)
        {
            tearDownSessionLocked()
        }
    }

    /// Decode H.264 NAL unit data
    /// - Parameters:
    ///   - data: H.264 NAL unit data (Annex-B or 4-byte length-prefixed AVCC; can include SPS/PPS or frame data)
    ///   - isKeyFrame: True if this is an I-frame
    ///   - timestamp: Presentation timestamp
    public func decode(_ data: Data, isKeyFrame: Bool, timestamp: CMTime) throws {
        guard !data.isEmpty else { return }

        sessionLock.lock()
        defer { sessionLock.unlock() }

        let nalUnits = Self.extractNALUnits(from: data)

        // Extract SPS/PPS whenever present (keyframes, config packets, or mid-stream updates)
        if !nalUnits.isEmpty {
            try updateFormatDescriptionLocked(from: nalUnits)
        } else if isKeyFrame {
            try updateFormatDescription(from: data)
        }

        guard let formatDescription = formatDescription else {
            throw DecoderError.noFormatDescription
        }

        // Filter out parameter-set NAL units (SPS = 7, PPS = 8) when building frame payload
        let payloadNALs: [Data]
        if !nalUnits.isEmpty {
            payloadNALs = nalUnits.filter { nalu in
                guard let firstByte = nalu.first else { return false }
                let nalType = firstByte & 0x1F
                return nalType != 7 && nalType != 8
            }
            // Config-only packet (only SPS/PPS, no video slice): format description is now ready
            guard !payloadNALs.isEmpty else { return }
        } else {
            payloadNALs = [data]
        }

        // VideoToolbox expects 4-byte length-prefixed AVCC NAL units (matching nalUnitHeaderLength = 4)
        let avccData = Self.convertToAVCC(nalUnits: payloadNALs)
        guard !avccData.isEmpty else { return }

        // Create decompression session if needed
        if decompressionSession == nil {
            try setupDecompressionSessionLocked(formatDescription: formatDescription)
        }

        guard let session = decompressionSession else {
            throw DecoderError.sessionNotReady
        }

        // Allocate a CoreMedia-owned CMBlockBuffer and copy bytes safely (no escaping pointer)
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avccData.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avccData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )

        guard createStatus == kCMBlockBufferNoErr, let blockBuffer = blockBuffer else {
            throw DecoderError.blockBufferCreationFailed(createStatus)
        }

        let copyStatus = avccData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
            guard let baseAddress = bytes.baseAddress else {
                return kCMBlockBufferBadPointerParameterErr
            }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avccData.count
            )
        }

        guard copyStatus == kCMBlockBufferNoErr else {
            throw DecoderError.blockBufferCreationFailed(copyStatus)
        }

        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: timestamp,
            decodeTimeStamp: .invalid
        )
        var sampleSize = avccData.count

        let sampleStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else {
            throw DecoderError.sampleBufferCreationFailed(sampleStatus)
        }

        // Mutate the underlying CFMutableDictionary attachment directly
        if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachmentsArray) > 0,
           let rawDict = CFArrayGetValueAtIndex(attachmentsArray, 0)
        {
            let dict = unsafeBitCast(rawDict, to: CFMutableDictionary.self)
            let key: CFString = kCMSampleAttachmentKey_NotSync
            let notSyncValue: CFBoolean = isKeyFrame ? kCFBooleanFalse : kCFBooleanTrue
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(key).toOpaque(),
                Unmanaged.passUnretained(notSyncValue).toOpaque()
            )
        }

        // Decode
        var infoFlags: VTDecodeInfoFlags = []
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )

        guard decodeStatus == noErr else {
            throw DecoderError.decodingFailed(decodeStatus)
        }
    }

    /// Start decoding
    public func start() {
        sessionLock.lock()
        isDecoding = true
        sessionLock.unlock()
    }

    /// Stop decoding and flush pending frames
    public func stop() async throws {
        try stopSync()
    }

    private func stopSync() throws {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        guard isDecoding else { return }
        isDecoding = false

        guard let session = decompressionSession else { return }

        // Flush remaining frames
        let status = VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard status == noErr else {
            throw DecoderError.flushFailed(status)
        }
    }

    /// Invalidate the decoder
    public func invalidate() {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        tearDownSessionLocked()
        formatDescription = nil
        cachedSPS = nil
        cachedPPS = nil
        isDecoding = false
    }

    // MARK: - Private Methods

    private func updateFormatDescription(from data: Data) throws {
        let nalUnits = Self.extractNALUnits(from: data)
        try updateFormatDescriptionLocked(from: nalUnits)
    }

    private func updateFormatDescriptionLocked(from nalUnits: [Data]) throws {
        var foundSPS: Data?
        var foundPPS: Data?

        for nalu in nalUnits {
            guard let firstByte = nalu.first else { continue }
            let nalType = firstByte & 0x1F
            if nalType == 7 {
                foundSPS = nalu
            } else if nalType == 8 {
                foundPPS = nalu
            }
        }

        let spsChanged = foundSPS != nil && foundSPS != cachedSPS
        let ppsChanged = foundPPS != nil && foundPPS != cachedPPS

        if let sps = foundSPS {
            cachedSPS = sps
        }
        if let pps = foundPPS {
            cachedPPS = pps
        }

        guard let sps = cachedSPS, let pps = cachedPPS else {
            return
        }

        if formatDescription == nil || spsChanged || ppsChanged {
            let newFormatDescription = try Self.createFormatDescription(sps: sps, pps: pps)
            formatDescription = newFormatDescription
            if let session = decompressionSession,
               !VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFormatDescription)
            {
                tearDownSessionLocked()
            }
        }
    }

    private func tearDownSessionLocked() {
        let session = decompressionSession
        let refCon = sessionRefCon
        decompressionSession = nil
        sessionRefCon = nil

        // Prevent future frame deliveries immediately, invalidate session synchronously so
        // no VideoToolbox callback can run after this point, then release the retained context.
        refCon?.takeUnretainedValue().invalidate()
        if let session = session {
            VTDecompressionSessionInvalidate(session)
        }
        refCon?.release()
    }

    private func setupDecompressionSessionLocked(formatDescription: CMFormatDescription) throws {
        tearDownSessionLocked()

        var session: VTDecompressionSession?

        // Decoder attributes
        let decoderAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue as Any,
            kCVPixelBufferOpenGLCompatibilityKey: kCFBooleanTrue as Any
        ]

        // Retain an independent CallbackContext for the session's lifetime so the C callback
        // can never access a deallocating VideoStreamDecoder.
        let context = CallbackContext(outputQueue: outputQueue, outputHandler: outputHandler)
        let retainedContext = Unmanaged.passRetained(context)

        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.decompressionOutputCallback,
            decompressionOutputRefCon: retainedContext.toOpaque()
        )

        // Create decompression session
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: decoderAttributes as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            retainedContext.release()
            throw DecoderError.sessionCreationFailed(status)
        }

        // Configure session for real-time playback
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)

        self.decompressionSession = session
        self.sessionRefCon = retainedContext
    }

    // MARK: - Decompression Callback

    private static let decompressionOutputCallback: VTDecompressionOutputCallback = { (
        decompressionOutputRefCon: UnsafeMutableRawPointer?,
        _: UnsafeMutableRawPointer?,
        status: OSStatus,
        _: VTDecodeInfoFlags,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp: CMTime,
        _: CMTime
    ) in
        guard status == noErr else {
            print("❌ [VideoStreamDecoder] Decompression error: \(status)")
            return
        }

        guard let imageBuffer = imageBuffer else {
            print("❌ [VideoStreamDecoder] No image buffer")
            return
        }

        guard let refCon = decompressionOutputRefCon else {
            print("❌ [VideoStreamDecoder] No refcon")
            return
        }

        let context = Unmanaged<CallbackContext>.fromOpaque(refCon).takeUnretainedValue()
        context.deliver(imageBuffer, timestamp: presentationTimeStamp)
    }

    /// Thread-safe callback box retained for the exact lifetime of a `VTDecompressionSession`.
    /// Released only after `VTDecompressionSessionInvalidate` has completed.
    private final class CallbackContext: @unchecked Sendable {
        private let outputQueue: DispatchQueue
        private let handlerLock: OSAllocatedUnfairLock<HandlerBox?>

        init(outputQueue: DispatchQueue, outputHandler: @escaping OutputHandler) {
            self.outputQueue = outputQueue
            self.handlerLock = OSAllocatedUnfairLock(initialState: HandlerBox(call: outputHandler))
        }

        func invalidate() {
            handlerLock.withLock { $0 = nil }
        }

        func deliver(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
            guard handlerLock.withLock({ $0 != nil }) else { return }
            let box = PixelBufferBox(pixelBuffer: pixelBuffer)
            outputQueue.async { [self] in
                guard let handler = handlerLock.withLock({ $0 }) else { return }
                handler.call(box.pixelBuffer, timestamp)
            }
        }
    }

    private struct HandlerBox: @unchecked Sendable {
        let call: OutputHandler
    }

    /// A decoded frame on its way from VideoToolbox's callback to `outputQueue`.
    ///
    /// Unchecked because `CVPixelBuffer` isn't `Sendable`. VideoToolbox hands over a finished
    /// frame, which nothing writes to afterwards, and CoreFoundation retains and releases atomically.
    private struct PixelBufferBox: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
    }

    // MARK: - Errors

    public enum DecoderError: Error {
        case noFormatDescription
        case sessionCreationFailed(OSStatus)
        case sessionNotReady
        case blockBufferCreationFailed(OSStatus)
        case sampleBufferCreationFailed(OSStatus)
        case decodingFailed(OSStatus)
        case flushFailed(OSStatus)
    }
}

// MARK: - H.264 NAL Unit Utilities

extension VideoStreamDecoder {
    /// Extracts raw H.264 NAL units (without start codes or length prefixes) from either
    /// Annex-B (3-byte `00 00 01` / 4-byte `00 00 00 01`) or AVCC (4-byte big-endian length-prefixed) data.
    static func extractNALUnits(from data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }

        return data.withUnsafeBytes { rawBuffer -> [Data] in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            let count = bytes.count
            guard count > 0 else { return [] }

            // 4-byte Annex-B start code at offset 0 is unambiguous for H.264 bitstreams
            let startsWith4ByteStartCode = count >= 4
                && bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0x00 && bytes[3] == 0x01

            // Prefer strict AVCC 4-byte length-prefixed framing when it does not begin with 00 00 00 01.
            // Checking AVCC before 3-byte start codes avoids misclassifying a 256..511-byte AVCC NAL
            // whose 4-byte big-endian length starts with 00 00 01 XX.
            if !startsWith4ByteStartCode, let avccNALs = parseAVCC(bytes: bytes) {
                return avccNALs
            }

            if let annexBNALs = parseAnnexB(bytes: bytes) {
                return annexBNALs
            }

            return []
        }
    }

    /// Extracts SPS (NAL type 7) and PPS (NAL type 8) parameter sets from Annex-B or AVCC data.
    static func extractParameterSets(from data: Data) -> (sps: Data?, pps: Data?) {
        var sps: Data?
        var pps: Data?
        for nalu in extractNALUnits(from: data) {
            guard let firstByte = nalu.first else { continue }
            let nalType = firstByte & 0x1F
            if nalType == 7 {
                sps = nalu
            } else if nalType == 8 {
                pps = nalu
            }
        }
        return (sps, pps)
    }

    /// Packs raw NAL units into 4-byte big-endian length-prefixed AVCC format.
    static func convertToAVCC(nalUnits: [Data]) -> Data {
        var totalSize = 0
        for nalu in nalUnits where !nalu.isEmpty {
            totalSize += 4 + nalu.count
        }
        var output = Data(capacity: totalSize)
        for nalu in nalUnits where !nalu.isEmpty {
            var length = UInt32(nalu.count).bigEndian
            withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
            output.append(nalu)
        }
        return output
    }

    private static func parseAVCC(bytes: UnsafeBufferPointer<UInt8>) -> [Data]? {
        let count = bytes.count
        guard count >= 5 else { return nil }

        var offset = 0
        var nalUnits: [Data] = []

        while offset < count {
            guard offset + 4 <= count else { return nil }
            let length = (Int(bytes[offset]) << 24)
                | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8)
                | Int(bytes[offset + 3])
            offset += 4

            guard length > 0, offset + length <= count else { return nil }
            let header = bytes[offset]
            // H.264 NAL header: forbidden_zero_bit (MSB) must be 0 and nal_unit_type non-zero
            guard (header & 0x80) == 0, (header & 0x1F) != 0 else { return nil }

            let nalu = Data(bytes: bytes.baseAddress! + offset, count: length)
            nalUnits.append(nalu)
            offset += length
        }

        return nalUnits.isEmpty ? nil : nalUnits
    }

    private static func parseAnnexB(bytes: UnsafeBufferPointer<UInt8>) -> [Data]? {
        let count = bytes.count
        guard count >= 4 else { return nil }

        // Find all start code positions (start index of prefix, length of prefix: 3 or 4)
        var startCodes: [(prefixStart: Int, payloadStart: Int)] = []
        var i = 0
        while i + 2 < count {
            if bytes[i] == 0x00 && bytes[i + 1] == 0x00 {
                if i + 3 < count && bytes[i + 2] == 0x00 && bytes[i + 3] == 0x01 {
                    startCodes.append((i, i + 4))
                    i += 4
                    continue
                } else if bytes[i + 2] == 0x01 {
                    startCodes.append((i, i + 3))
                    i += 3
                    continue
                }
            }
            i += 1
        }

        guard !startCodes.isEmpty else { return nil }

        var nalUnits: [Data] = []
        nalUnits.reserveCapacity(startCodes.count)

        for idx in 0..<startCodes.count {
            let payloadStart = startCodes[idx].payloadStart
            var payloadEnd = (idx + 1 < startCodes.count) ? startCodes[idx + 1].prefixStart : count

            // Strip any trailing zero padding bytes preceding the next start code
            while payloadEnd > payloadStart && bytes[payloadEnd - 1] == 0x00 && idx + 1 < startCodes.count {
                payloadEnd -= 1
            }

            if payloadEnd > payloadStart {
                let nalu = Data(bytes: bytes.baseAddress! + payloadStart, count: payloadEnd - payloadStart)
                nalUnits.append(nalu)
            }
        }

        return nalUnits.isEmpty ? nil : nalUnits
    }

    /// Create format description from H.264 parameter sets (SPS/PPS)
    /// - Parameters:
    ///   - sps: Sequence Parameter Set NAL unit
    ///   - pps: Picture Parameter Set NAL unit
    /// - Returns: CMFormatDescription for H.264 video
    public static func createFormatDescription(sps: Data, pps: Data) throws -> CMFormatDescription {
        guard !sps.isEmpty, !pps.isEmpty else {
            throw DecoderError.noFormatDescription
        }

        var formatDescription: CMFormatDescription?

        // Use withUnsafeBytes to get proper pointers
        try sps.withUnsafeBytes { spsBytes in
            try pps.withUnsafeBytes { ppsBytes in
                guard let spsPointer = spsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPointer = ppsBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw DecoderError.noFormatDescription
                }

                let pointers: [UnsafePointer<UInt8>] = [spsPointer, ppsPointer]
                let sizes: [Int] = [sps.count, pps.count]

                let status = pointers.withUnsafeBufferPointer { pointersBuffer in
                    sizes.withUnsafeBufferPointer { sizesBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointersBuffer.baseAddress!,
                            parameterSetSizes: sizesBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &formatDescription
                        )
                    }
                }

                guard status == noErr else {
                    throw DecoderError.sessionCreationFailed(status)
                }
            }
        }

        guard let formatDescription = formatDescription else {
            throw DecoderError.sessionCreationFailed(-1)
        }

        return formatDescription
    }
}
