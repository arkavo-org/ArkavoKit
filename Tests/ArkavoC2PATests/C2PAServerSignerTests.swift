import CryptoKit
import XCTest
@testable import ArkavoC2PA

/// Server-signed C2PA for BMFF (MOV/MP4/M4A): the client hashes the file, the
/// server signs a data-hash manifest, and the client appends it as a top-level
/// C2PA `uuid` box whose bytes are the manifest's only hash exclusion.
final class C2PAServerSignerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("C2PAServerSignerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Manifest box

    func testManifestBoxWrapsJUMBFInC2PAUUIDBox() {
        let jumbf = Data([0xAA, 0xBB, 0xCC])
        let box = C2PAManifestBox.make(jumbf: jumbf)

        var expected = Data()
        expected.append(contentsOf: [0x00, 0x00, 0x00, 0x30]) // 45 + 3
        expected.append(contentsOf: Array("uuid".utf8))
        expected.append(contentsOf: [
            0xD8, 0xFE, 0xC3, 0xD6, 0x1B, 0x0E, 0x48, 0x3C,
            0x92, 0x97, 0x58, 0x28, 0x87, 0x7E, 0xC4, 0x81,
        ])
        expected.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // version + flags
        expected.append(contentsOf: Array("manifest".utf8) + [0x00])
        expected.append(contentsOf: [UInt8](repeating: 0, count: 8)) // merkle offset
        expected.append(jumbf)

        XCTAssertEqual(C2PAManifestBox.headerSize, 45)
        XCTAssertEqual(box, expected)
    }

    // MARK: - Signing

    func testSignAppendsManifestBoxAfterOriginalBytes() async throws {
        let input = try writeFile("in.mov", makeBMFF(payloadSize: 1000))
        let output = directory.appendingPathComponent("out.mov")
        let jumbf = Data(repeating: 0x5A, count: 200)
        let recorder = RequestRecorder()
        let signer = C2PAServerSigner { request in
            await recorder.record(request)
            return jumbf
        }

        let result = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())

        let original = try Data(contentsOf: input)
        let signed = try Data(contentsOf: output)
        XCTAssertEqual(signed, original + C2PAManifestBox.make(jumbf: jumbf))

        let start = UInt64(original.count)
        let end = start + UInt64(C2PAManifestBox.headerSize + jumbf.count)
        XCTAssertEqual(result.manifestRange, start..<end)
        XCTAssertEqual(result.contentHash, sha256Hex(original))

        let requests = await recorder.requests
        let last = try XCTUnwrap(requests.last)
        XCTAssertEqual(last.contentHash, sha256Hex(original))
        XCTAssertEqual(last.exclusionRanges, [C2PAExclusionRange(start: start, end: end, boxType: "uuid")])
        XCTAssertEqual(last.containerFormat, .mov)
    }

    func testSignRepeatsUntilTheReservedRangeFitsTheManifest() async throws {
        let input = try writeFile("in.mov", makeBMFF(payloadSize: 64))
        let output = directory.appendingPathComponent("out.mov")
        let recorder = RequestRecorder()
        let signer = C2PAServerSigner { request in
            let call = await recorder.record(request)
            return Data(repeating: UInt8(call), count: 100)
        }

        let result = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())

        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(result.requestCount, 2)
        let range = try XCTUnwrap(requests.last?.exclusionRanges.first)
        XCTAssertEqual(range.end - range.start, UInt64(C2PAManifestBox.headerSize + 100))

        // The embedded manifest is the one signed over the fitted range.
        let signed = try Data(contentsOf: output)
        XCTAssertEqual(signed.suffix(100), Data(repeating: 2, count: 100))
    }

    func testSignRetriesWithTheLengthTheServerRequires() async throws {
        let input = try writeFile("in.mov", makeBMFF(payloadSize: 64))
        let output = directory.appendingPathComponent("out.mov")
        let recorder = RequestRecorder()
        let signer = C2PAServerSigner { request in
            let call = await recorder.record(request)
            guard call > 1 else {
                throw C2PASigningService.ServiceError.exclusionLengthMismatch(
                    requiredLength: C2PAManifestBox.headerSize + 100
                )
            }
            return Data(repeating: 9, count: 100)
        }

        let result = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())

        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(result.requestCount, 2)
        let range = try XCTUnwrap(requests.last?.exclusionRanges.first)
        XCTAssertEqual(range.end - range.start, UInt64(C2PAManifestBox.headerSize + 100))
        XCTAssertEqual(try Data(contentsOf: output).suffix(100), Data(repeating: 9, count: 100))
    }

    func testSignStopsWhenTheRequiredLengthKeepsChanging() async throws {
        let input = try writeFile("in.mov", makeBMFF(payloadSize: 64))
        let output = directory.appendingPathComponent("out.mov")
        let recorder = RequestRecorder()
        let signer = C2PAServerSigner { request in
            let call = await recorder.record(request)
            throw C2PASigningService.ServiceError.exclusionLengthMismatch(requiredLength: 200 + call)
        }

        do {
            _ = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())
            XCTFail("expected manifestSizeDidNotSettle")
        } catch C2PAServerSigner.SigningError.manifestSizeDidNotSettle {
        }
        let count = await recorder.requests.count
        XCTAssertEqual(count, C2PAServerSigner.maxRequests)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testSignFailsWithoutWritingWhenManifestSizeNeverSettles() async throws {
        let input = try writeFile("in.mov", makeBMFF(payloadSize: 64))
        let output = directory.appendingPathComponent("out.mov")
        let recorder = RequestRecorder()
        let signer = C2PAServerSigner { request in
            let call = await recorder.record(request)
            return Data(count: 100 + call * 10)
        }

        do {
            _ = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())
            XCTFail("expected manifestSizeDidNotSettle")
        } catch C2PAServerSigner.SigningError.manifestSizeDidNotSettle {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testSignHashesFilesLargerThanOneReadChunk() async throws {
        let bytes = makeBMFF(payloadSize: 3 * 1024 * 1024 + 17)
        let input = try writeFile("big.mp4", bytes)
        let output = directory.appendingPathComponent("out.mp4")
        let signer = C2PAServerSigner { _ in Data(count: 10) }

        let result = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())

        XCTAssertEqual(result.contentHash, sha256Hex(bytes))
    }

    func testSignHandlesBoxesWithLargeSizeHeaders() async throws {
        var bytes = ftypBox()
        let payload = Data(repeating: 7, count: 32)
        bytes.append(contentsOf: [0, 0, 0, 1]) // size 1 → 64-bit largesize follows
        bytes.append(contentsOf: Array("mdat".utf8))
        bytes.append(bigEndian: UInt64(16 + payload.count))
        bytes.append(payload)
        let input = try writeFile("in.mov", bytes)
        let output = directory.appendingPathComponent("out.mov")
        let signer = C2PAServerSigner { _ in Data(count: 10) }

        let result = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())

        XCTAssertEqual(result.manifestRange.lowerBound, UInt64(bytes.count))
    }

    func testSignMapsM4AToTheMP4ContainerFormat() async throws {
        let input = try writeFile("voice.m4a", makeBMFF(payloadSize: 16))
        let output = directory.appendingPathComponent("voice-signed.m4a")
        let recorder = RequestRecorder()
        let signer = C2PAServerSigner { request in
            await recorder.record(request)
            return Data(count: 10)
        }

        _ = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())

        let format = await recorder.requests.last?.containerFormat
        XCTAssertEqual(format, .mp4)
    }

    func testSignRejectsAFileThatAlreadyHasAManifest() async throws {
        let signedBytes = makeBMFF(payloadSize: 16) + C2PAManifestBox.make(jumbf: Data(count: 10))
        let input = try writeFile("signed.mov", signedBytes)
        let output = directory.appendingPathComponent("out.mov")
        let signer = C2PAServerSigner { _ in
            XCTFail("server should not be called")
            return Data()
        }

        do {
            _ = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())
            XCTFail("expected alreadySigned")
        } catch C2PAServerSigner.SigningError.alreadySigned {
        }
    }

    func testSignRejectsFilesThatAreNotBMFF() async throws {
        let input = try writeFile("notes.mov", Data("not a movie at all".utf8))
        let output = directory.appendingPathComponent("out.mov")
        let signer = C2PAServerSigner { _ in Data() }

        do {
            _ = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())
            XCTFail("expected unsupportedContainer")
        } catch C2PAServerSigner.SigningError.unsupportedContainer {
        }
    }

    func testSignRejectsAFinalBoxThatRunsToEndOfFile() async throws {
        // A size-0 box extends to EOF, so an appended manifest would land inside it.
        var bytes = ftypBox()
        bytes.append(contentsOf: [0, 0, 0, 0])
        bytes.append(contentsOf: Array("mdat".utf8))
        bytes.append(Data(repeating: 1, count: 32))
        let input = try writeFile("in.mov", bytes)
        let output = directory.appendingPathComponent("out.mov")
        let signer = C2PAServerSigner { _ in Data(count: 10) }

        do {
            _ = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())
            XCTFail("expected unsupportedContainer")
        } catch C2PAServerSigner.SigningError.unsupportedContainer {
        }
    }

    func testSignRejectsUnknownFileExtensions() async throws {
        let input = try writeFile("in.avi", makeBMFF(payloadSize: 16))
        let output = directory.appendingPathComponent("out.avi")
        let signer = C2PAServerSigner { _ in Data(count: 10) }

        do {
            _ = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())
            XCTFail("expected unsupportedContainer")
        } catch C2PAServerSigner.SigningError.unsupportedContainer {
        }
    }

    func testSignRefusesToOverwriteAnExistingOutput() async throws {
        let input = try writeFile("in.mov", makeBMFF(payloadSize: 16))
        let output = try writeFile("out.mov", Data("keep me".utf8))
        let signer = C2PAServerSigner { _ in Data(count: 10) }

        do {
            _ = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())
            XCTFail("expected outputExists")
        } catch C2PAServerSigner.SigningError.outputExists {
        }
        XCTAssertEqual(try Data(contentsOf: output), Data("keep me".utf8))
    }

    // MARK: - Fixtures

    private func metadata() -> C2PASigningMetadata {
        C2PASigningMetadata(
            title: "Test Recording",
            creator: "tester@arkavo.net",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            software: "ArkavoC2PATests"
        )
    }

    private func writeFile(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func ftypBox() -> Data {
        var box = Data([0, 0, 0, 20])
        box.append(contentsOf: Array("ftypqt  ".utf8))
        box.append(contentsOf: [0, 0, 0, 0])
        box.append(contentsOf: Array("qt  ".utf8))
        return box
    }

    private func makeBMFF(payloadSize: Int) -> Data {
        var data = ftypBox()
        data.append(bigEndian: UInt32(8 + payloadSize))
        data.append(contentsOf: Array("mdat".utf8))
        data.append(Data((0..<payloadSize).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        return data
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

actor RequestRecorder {
    private(set) var requests: [C2PASignRequest] = []

    /// Records the request and returns its 1-based call number.
    @discardableResult
    func record(_ request: C2PASignRequest) -> Int {
        requests.append(request)
        return requests.count
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
