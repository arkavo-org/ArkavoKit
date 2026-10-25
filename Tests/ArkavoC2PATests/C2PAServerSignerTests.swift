import CryptoKit
import XCTest
@testable import ArkavoC2PA

/// Server-signed C2PA for BMFF (MOV/MP4/M4A): the client hashes the file, the
/// server signs a data-hash manifest, and the client writes it in a C2PA `uuid` box
/// right after `ftyp` (spec A.5.3), shifting the media and patching chunk offsets.
/// The box is the manifest's only hash exclusion.
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

    func testManifestBoxPadsTheManifestWithZerosToTheReservedSize() {
        let jumbf = Data([0xAA, 0xBB, 0xCC])
        let box = C2PAManifestBox.make(jumbf: jumbf, size: 60)

        XCTAssertEqual(box.count, 60)
        XCTAssertEqual(box.prefix(4), Data([0, 0, 0, 60]))
        XCTAssertEqual(box.dropFirst(45).prefix(3), jumbf)
        XCTAssertEqual(box.suffix(12), Data(count: 12))
    }

    // MARK: - Placement

    func testSignPutsTheManifestBoxRightAfterFtyp() async throws {
        let movie = makeMovie(payloadSize: 1000, moovFirst: false)
        let input = try writeFile("in.mov", movie.bytes)
        let output = directory.appendingPathComponent("out.mov")
        let jumbf = Data(repeating: 0x5A, count: 200)
        let recorder = RequestRecorder()
        let signer = C2PAServerSigner(reservation: 4096) { request in
            await recorder.record(request)
            return jumbf
        }

        let result = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())

        let signed = try Data(contentsOf: output)
        let ftypEnd = 20
        XCTAssertEqual(topLevelTypes(signed), ["ftyp", "uuid", "mdat", "moov"])
        XCTAssertEqual(signed.prefix(ftypEnd), movie.bytes.prefix(ftypEnd))
        XCTAssertEqual(signed.subdata(in: ftypEnd..<ftypEnd + 4096), C2PAManifestBox.make(jumbf: jumbf, size: 4096))
        XCTAssertEqual(result.manifestRange, UInt64(ftypEnd)..<UInt64(ftypEnd + 4096))

        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.exclusionRanges, [C2PAExclusionRange(start: 20, end: 4116, boxType: "uuid")])
        XCTAssertEqual(request.containerFormat, .mov)
        XCTAssertEqual(request.contentHash, sha256Hex(signed, excluding: ftypEnd..<ftypEnd + 4096))
        XCTAssertEqual(result.contentHash, request.contentHash)

        XCTAssertEqual(try chunkOffsets(signed), .stco(movie.chunkOffsets.map { $0 + 4096 }))
        XCTAssertEqual(mdatPayload(signed), mdatPayload(movie.bytes))
    }

    func testSignShiftsChunkOffsetsWhenMoovComesFirst() async throws {
        let movie = makeMovie(payloadSize: 1000, moovFirst: true)
        let input = try writeFile("in.mov", movie.bytes)
        let output = directory.appendingPathComponent("out.mov")
        let signer = C2PAServerSigner(reservation: 4096) { _ in Data(count: 100) }

        _ = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())

        let signed = try Data(contentsOf: output)
        XCTAssertEqual(topLevelTypes(signed), ["ftyp", "uuid", "moov", "mdat"])
        let shifted = movie.chunkOffsets.map { $0 + 4096 }
        XCTAssertEqual(try chunkOffsets(signed), .stco(shifted))
        // Each patched offset still points at the same chunk bytes.
        for (old, new) in zip(movie.chunkOffsets, shifted) {
            XCTAssertEqual(signed.subdata(in: Int(new)..<Int(new) + 8), movie.bytes.subdata(in: Int(old)..<Int(old) + 8))
        }
    }

    func testSignShiftsCo64ChunkOffsets() async throws {
        let movie = makeMovie(payloadSize: 1000, moovFirst: false, table: .co64)
        let input = try writeFile("in.mp4", movie.bytes)
        let output = directory.appendingPathComponent("out.mp4")
        let signer = C2PAServerSigner(reservation: 4096) { _ in Data(count: 100) }

        _ = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())

        XCTAssertEqual(try chunkOffsets(Data(contentsOf: output)), .co64(movie.chunkOffsets.map { $0 + 4096 }))
    }

    func testSignConvertsStcoToCo64WhenAnOffsetPassesFourGiB() async throws {
        let movie = makeMovie(payloadSize: 64, moovFirst: false, extraOffsets: [0xFFFF_F000])
        let input = try writeFile("in.mov", movie.bytes)
        let output = directory.appendingPathComponent("out.mov")
        let signer = C2PAServerSigner(reservation: 8192) { _ in Data(count: 100) }

        _ = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())

        let signed = try Data(contentsOf: output)
        guard case .co64(let entries) = try chunkOffsets(signed) else {
            return XCTFail("expected the table to become co64")
        }
        // The real chunks sit in mdat, before moov, so they move by the box size only.
        // (The 0xFFFF_F000 entry is a placeholder past the fixture's end.)
        XCTAssertEqual(Array(entries.prefix(3)), movie.chunkOffsets.prefix(3).map { $0 + 8192 })
        XCTAssertGreaterThan(entries[3], UInt64(UInt32.max))
        XCTAssertEqual(topLevelTypes(signed), ["ftyp", "uuid", "mdat", "moov"])
        XCTAssertEqual(mdatPayload(signed), mdatPayload(movie.bytes))
    }

    func testSignShiftsChunksBehindAMoovThatGrewFromTheConversion() async throws {
        // moov comes first, so converting stco to co64 (4 more bytes per entry) also
        // moves every chunk behind it.
        let movie = makeMovie(payloadSize: 64, moovFirst: true, extraOffsets: [0xFFFF_F000])
        let input = try writeFile("in.mov", movie.bytes)
        let output = directory.appendingPathComponent("out.mov")
        let signer = C2PAServerSigner(reservation: 8192) { _ in Data(count: 100) }

        _ = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())

        let signed = try Data(contentsOf: output)
        let growth = UInt64(4 * movie.chunkOffsets.count)
        let shifted = movie.chunkOffsets.map { $0 + 8192 + growth }
        XCTAssertEqual(try chunkOffsets(signed), .co64(shifted))
        let first = Int(movie.chunkOffsets[0])
        XCTAssertEqual(
            signed.subdata(in: Int(shifted[0])..<Int(shifted[0]) + 8),
            movie.bytes.subdata(in: first..<first + 8)
        )
        XCTAssertEqual(mdatPayload(signed), mdatPayload(movie.bytes))
    }

    func testSignHandlesBoxesWithLargeSizeHeaders() async throws {
        let movie = makeMovie(payloadSize: 32, moovFirst: false, largeMdatHeader: true)
        let input = try writeFile("in.mov", movie.bytes)
        let output = directory.appendingPathComponent("out.mov")
        let signer = C2PAServerSigner(reservation: 4096) { _ in Data(count: 10) }

        let result = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())

        let signed = try Data(contentsOf: output)
        XCTAssertEqual(result.manifestRange.lowerBound, 20)
        XCTAssertEqual(try chunkOffsets(signed), .stco(movie.chunkOffsets.map { $0 + 4096 }))
        XCTAssertEqual(mdatPayload(signed), mdatPayload(movie.bytes))
    }

    func testSignHashesFilesLargerThanOneReadChunk() async throws {
        let movie = makeMovie(payloadSize: 3 * 1024 * 1024 + 17, moovFirst: false)
        let input = try writeFile("big.mp4", movie.bytes)
        let output = directory.appendingPathComponent("out.mp4")
        let signer = C2PAServerSigner(reservation: 4096) { _ in Data(count: 10) }

        let result = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())

        let signed = try Data(contentsOf: output)
        XCTAssertEqual(result.contentHash, sha256Hex(signed, excluding: 20..<20 + 4096))
    }

    // MARK: - Agreeing on the box size

    func testSignRetriesWithTheLengthTheServerRequires() async throws {
        let input = try writeFile("in.mov", makeMovie(payloadSize: 64, moovFirst: false).bytes)
        let output = directory.appendingPathComponent("out.mov")
        let recorder = RequestRecorder()
        let signer = C2PAServerSigner(reservation: 4096) { request in
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
        XCTAssertEqual(requests.map { $0.exclusionRanges.first.map { $0.end - $0.start } }, [4096, 145])
        XCTAssertEqual(result.requestCount, 2)
        XCTAssertEqual(result.manifestRange, 20..<165)
        let signed = try Data(contentsOf: output)
        XCTAssertEqual(signed.subdata(in: 20..<165), C2PAManifestBox.make(jumbf: Data(repeating: 9, count: 100)))
        XCTAssertEqual(requests[1].contentHash, sha256Hex(signed, excluding: 20..<165))
    }

    func testSignAsksAgainWhenTheManifestDoesNotFitTheReservation() async throws {
        let input = try writeFile("in.mov", makeMovie(payloadSize: 64, moovFirst: false).bytes)
        let output = directory.appendingPathComponent("out.mov")
        let recorder = RequestRecorder()
        let signer = C2PAServerSigner(reservation: 100) { request in
            let call = await recorder.record(request)
            return Data(repeating: UInt8(call), count: 200)
        }

        let result = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())

        let requests = await recorder.requests
        XCTAssertEqual(requests.map { $0.exclusionRanges.first.map { $0.end - $0.start } }, [100, 245])
        XCTAssertEqual(result.requestCount, 2)
        // The embedded manifest is the one signed over the final range.
        let signed = try Data(contentsOf: output)
        XCTAssertEqual(signed.subdata(in: 20 + 45..<20 + 245), Data(repeating: 2, count: 200))
    }

    func testSignStopsWhenTheRequiredLengthKeepsChanging() async throws {
        let input = try writeFile("in.mov", makeMovie(payloadSize: 64, moovFirst: false).bytes)
        let output = directory.appendingPathComponent("out.mov")
        let recorder = RequestRecorder()
        let signer = C2PAServerSigner(reservation: 4096) { request in
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
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["in.mov"])
    }

    func testSignFailsWithoutWritingWhenTheManifestKeepsOutgrowingTheBox() async throws {
        let input = try writeFile("in.mov", makeMovie(payloadSize: 64, moovFirst: false).bytes)
        let output = directory.appendingPathComponent("out.mov")
        let recorder = RequestRecorder()
        let signer = C2PAServerSigner(reservation: 50) { request in
            let call = await recorder.record(request)
            return Data(count: 100 * call)
        }

        do {
            _ = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())
            XCTFail("expected manifestSizeDidNotSettle")
        } catch C2PAServerSigner.SigningError.manifestSizeDidNotSettle {
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["in.mov"])
    }

    func testSignMapsM4AToTheMP4ContainerFormat() async throws {
        let input = try writeFile("voice.m4a", makeMovie(payloadSize: 16, moovFirst: false).bytes)
        let output = directory.appendingPathComponent("voice-signed.m4a")
        let recorder = RequestRecorder()
        let signer = C2PAServerSigner(reservation: 4096) { request in
            await recorder.record(request)
            return Data(count: 10)
        }

        _ = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())

        let format = await recorder.requests.last?.containerFormat
        XCTAssertEqual(format, .mp4)
    }

    // MARK: - Refusals

    func testSignRejectsAFileThatAlreadyHasAManifest() async throws {
        let signedBytes = makeMovie(payloadSize: 16, moovFirst: false).bytes + C2PAManifestBox.make(jumbf: Data(count: 10))
        try await assertRefused(signedBytes) { error in
            guard case .alreadySigned = error else { return false }
            return true
        }
    }

    func testSignRejectsFilesThatAreNotBMFF() async throws {
        try await assertUnsupported(Data("not a movie at all".utf8))
    }

    func testSignRejectsAFinalBoxThatRunsToEndOfFile() async throws {
        var bytes = ftypBox() + moovBox(chunkTable(.stco, [28]))
        bytes.append(contentsOf: [0, 0, 0, 0])
        bytes.append(contentsOf: Array("mdat".utf8))
        bytes.append(Data(repeating: 1, count: 32))
        try await assertUnsupported(bytes)
    }

    func testSignRejectsAFileWithoutMoov() async throws {
        try await assertUnsupported(ftypBox() + box("mdat", Data(repeating: 1, count: 32)))
    }

    func testSignRejectsAFileWithTwoMoovBoxes() async throws {
        let moov = moovBox(chunkTable(.stco, [28]))
        try await assertUnsupported(ftypBox() + box("mdat", Data(repeating: 1, count: 32)) + moov + moov)
    }

    func testSignRejectsFragmentedMovies() async throws {
        let moov = box("moov", box("mvex", Data(count: 8)) + box("trak", box("mdia", box("minf", box("stbl", chunkTable(.stco, [28]))))))
        try await assertUnsupported(ftypBox() + box("mdat", Data(repeating: 1, count: 32)) + moov)
    }

    func testSignRejectsMoviesWithAuxiliaryInfoOffsets() async throws {
        // `saio` holds absolute file offsets this signer does not rewrite.
        let stbl = chunkTable(.stco, [28]) + fullBox("saio", Data(count: 8))
        let moov = box("moov", box("trak", box("mdia", box("minf", box("stbl", stbl)))))
        try await assertUnsupported(ftypBox() + box("mdat", Data(repeating: 1, count: 32)) + moov)
    }

    func testSignRejectsUnknownFileExtensions() async throws {
        let input = try writeFile("in.avi", makeMovie(payloadSize: 16, moovFirst: false).bytes)
        let output = directory.appendingPathComponent("out.avi")
        let signer = C2PAServerSigner { _ in Data(count: 10) }

        do {
            _ = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())
            XCTFail("expected unsupportedContainer")
        } catch C2PAServerSigner.SigningError.unsupportedContainer {
        }
    }

    func testSignRefusesToOverwriteAnExistingOutput() async throws {
        let input = try writeFile("in.mov", makeMovie(payloadSize: 16, moovFirst: false).bytes)
        let output = try writeFile("out.mov", Data("keep me".utf8))
        let signer = C2PAServerSigner { _ in Data(count: 10) }

        do {
            _ = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())
            XCTFail("expected outputExists")
        } catch C2PAServerSigner.SigningError.outputExists {
        }
        XCTAssertEqual(try Data(contentsOf: output), Data("keep me".utf8))
    }

    // MARK: - Helpers

    private func assertUnsupported(_ bytes: Data, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await assertRefused(bytes, file: file, line: line) { error in
            guard case .unsupportedContainer = error else { return false }
            return true
        }
    }

    private func assertRefused(
        _ bytes: Data,
        file: StaticString = #filePath,
        line: UInt = #line,
        matches: (C2PAServerSigner.SigningError) -> Bool
    ) async throws {
        let input = try writeFile("in-\(UUID().uuidString).mov", bytes)
        let output = directory.appendingPathComponent("out-\(UUID().uuidString).mov")
        let signer = C2PAServerSigner { _ in
            XCTFail("server should not be called", file: file, line: line)
            return Data()
        }
        do {
            _ = try await signer.sign(inputFile: input, outputFile: output, metadata: metadata())
            XCTFail("expected a refusal", file: file, line: line)
        } catch let error as C2PAServerSigner.SigningError {
            XCTAssertTrue(matches(error), "unexpected \(error)", file: file, line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), file: file, line: line)
    }

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

    private func sha256Hex(_ data: Data, excluding range: Range<Int>) -> String {
        var hasher = SHA256()
        hasher.update(data: data.prefix(range.lowerBound))
        hasher.update(data: data.dropFirst(range.upperBound))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - BMFF fixtures

enum ChunkTableKind { case stco, co64 }

enum ChunkOffsets: Equatable {
    case stco([UInt64])
    case co64([UInt64])
}

struct MovieFixture {
    let bytes: Data
    /// Absolute file offsets listed in the chunk-offset table
    let chunkOffsets: [UInt64]
}

func box(_ type: String, _ payload: Data) -> Data {
    var data = Data()
    data.append(bigEndian: UInt32(8 + payload.count))
    data.append(contentsOf: Array(type.utf8))
    data.append(payload)
    return data
}

func fullBox(_ type: String, _ payload: Data) -> Data {
    box(type, Data([0, 0, 0, 0]) + payload)
}

func ftypBox() -> Data {
    box("ftyp", Data("qt  ".utf8) + Data([0, 0, 0, 0]) + Data("qt  ".utf8))
}

func chunkTable(_ kind: ChunkTableKind, _ offsets: [UInt64]) -> Data {
    var payload = Data()
    payload.append(bigEndian: UInt32(offsets.count))
    for offset in offsets {
        switch kind {
        case .stco: payload.append(bigEndian: UInt32(offset))
        case .co64: payload.append(bigEndian: offset)
        }
    }
    return fullBox(kind == .stco ? "stco" : "co64", payload)
}

func moovBox(_ table: Data) -> Data {
    box("moov", box("trak", box("mdia", box("minf", box("stbl", table)))))
}

/// `ftyp`, then `mdat` and `moov` in either order. The chunk-offset table points at
/// three chunks inside `mdat`, followed by any `extraOffsets` as given.
func makeMovie(
    payloadSize: Int,
    moovFirst: Bool,
    table: ChunkTableKind = .stco,
    extraOffsets: [UInt64] = [],
    largeMdatHeader: Bool = false
) -> MovieFixture {
    let ftyp = ftypBox()
    let payload = Data((0..<payloadSize).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let mdatHeaderSize = largeMdatHeader ? 16 : 8
    let relative = [0, payloadSize / 3, 2 * payloadSize / 3].map(UInt64.init)
    let moovSize = moovBox(chunkTable(table, Array(repeating: 0, count: relative.count + extraOffsets.count))).count
    let payloadStart = UInt64(ftyp.count + (moovFirst ? moovSize : 0) + mdatHeaderSize)
    let offsets = relative.map { payloadStart + $0 } + extraOffsets

    var mdat = Data()
    if largeMdatHeader {
        mdat.append(contentsOf: [0, 0, 0, 1])
        mdat.append(contentsOf: Array("mdat".utf8))
        mdat.append(bigEndian: UInt64(16 + payloadSize))
        mdat.append(payload)
    } else {
        mdat = box("mdat", payload)
    }
    let moov = moovBox(chunkTable(table, offsets))
    return MovieFixture(bytes: ftyp + (moovFirst ? moov + mdat : mdat + moov), chunkOffsets: offsets)
}

private struct ParsedBox {
    let type: String
    let range: Range<Int>
    let payload: Range<Int>
}

private func parseBoxes(_ data: Data, in range: Range<Int>) -> [ParsedBox] {
    var boxes: [ParsedBox] = []
    var offset = range.lowerBound
    while offset + 8 <= range.upperBound {
        var size = Int(data.subdata(in: offset..<offset + 4).reduce(0) { $0 << 8 | UInt64($1) })
        let type = String(decoding: data.subdata(in: offset + 4..<offset + 8), as: UTF8.self)
        var header = 8
        if size == 1 {
            size = Int(data.subdata(in: offset + 8..<offset + 16).reduce(0) { $0 << 8 | UInt64($1) })
            header = 16
        }
        guard size >= header, offset + size <= range.upperBound else { break }
        boxes.append(ParsedBox(type: type, range: offset..<offset + size, payload: offset + header..<offset + size))
        offset += size
    }
    return boxes
}

func topLevelTypes(_ data: Data) -> [String] {
    parseBoxes(data, in: 0..<data.count).map(\.type)
}

func mdatPayload(_ data: Data) -> Data? {
    parseBoxes(data, in: 0..<data.count).first { $0.type == "mdat" }.map { data.subdata(in: $0.payload) }
}

struct FixtureError: Error {}

func chunkOffsets(_ data: Data) throws -> ChunkOffsets {
    var level = parseBoxes(data, in: 0..<data.count)
    for type in ["moov", "trak", "mdia", "minf", "stbl"] {
        guard let parent = level.first(where: { $0.type == type }) else { throw FixtureError() }
        level = parseBoxes(data, in: parent.payload)
    }
    guard let table = level.first(where: { $0.type == "stco" || $0.type == "co64" }) else { throw FixtureError() }
    let body = table.payload.lowerBound + 4 // version + flags
    let count = Int(data.subdata(in: body..<body + 4).reduce(0) { $0 << 8 | UInt64($1) })
    let width = table.type == "stco" ? 4 : 8
    let entries = (0..<count).map { i -> UInt64 in
        let start = body + 4 + i * width
        return data.subdata(in: start..<start + width).reduce(0) { $0 << 8 | UInt64($1) }
    }
    XCTAssertEqual(table.range.count, 16 + count * width, "table size")
    return table.type == "stco" ? .stco(entries) : .co64(entries)
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
